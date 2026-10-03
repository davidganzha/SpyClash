import Network
import XCTest
@testable import SpyClash

@MainActor
final class LocalNetworkPermissionLifecycleTests: XCTestCase {
    private let policyDenied = NWError.dns(-65570)

    private func makeCoordinator(
        _ browsers: PermissionBrowserHarness,
        _ clock: PermissionTestClock
    ) -> OnboardingPermissionCoordinator {
        OnboardingPermissionCoordinator(
            localNetworkBrowserFactory: browsers.makeBrowser,
            localNetworkSleep: clock.sleep
        )
    }

    private func expectSleep(_ duration: Duration, clock: PermissionTestClock) -> XCTestExpectation {
        let scheduled = expectation(description: "Permission delay scheduled: \(duration)")
        clock.onNextSleep(duration) { scheduled.fulfill() }
        return scheduled
    }

    private func expectBrowser(_ browsers: PermissionBrowserHarness) -> XCTestExpectation {
        let started = expectation(description: "Permission browser started")
        browsers.onNextStart = { started.fulfill() }
        return started
    }

    func testProvisionalPolicyDenialDuringSystemPromptCanBecomeGranted() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        coordinator.setApplicationActive(false)
        let started = expectBrowser(browsers)
        let request = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [started], timeout: 1)
        let browser = try XCTUnwrap(browsers.browsers.first)
        browser.emit(.waiting(policyDenied))
        XCTAssertEqual(coordinator.localNetworkStatus, .requesting)
        XCTAssertEqual(browser.cancelCount, 0)

        let confirmationDelay = expectSleep(.milliseconds(600), clock: clock)
        coordinator.setApplicationActive(true)
        await fulfillment(of: [confirmationDelay], timeout: 1)
        browser.emit(.ready)
        let didRequest = await request.value
        XCTAssertTrue(didRequest)
        XCTAssertEqual(coordinator.localNetworkStatus, .granted)
        XCTAssertTrue(coordinator.localNetworkStatus.allowsRadarInvitationSettings)
        XCTAssertEqual(browser.cancelCount, 1)
        // A timer from the provisional denial must not undo the grant.
        clock.wakeAll()
        await Task.yield()
        XCTAssertEqual(coordinator.localNetworkStatus, .granted)
    }

    func testDeniedThenSettingsGrantRequiresNewVerifiedBrowserResult() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        coordinator.setApplicationActive(true)
        let firstStarted = expectBrowser(browsers)
        let firstRequest = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let first = try XCTUnwrap(browsers.browsers.first)
        let initialDelay = expectSleep(.milliseconds(600), clock: clock)
        first.emit(.waiting(policyDenied))
        await fulfillment(of: [initialDelay], timeout: 1)
        let verificationStarted = expectBrowser(browsers)
        clock.wakeFirst(.milliseconds(600))
        await fulfillment(of: [verificationStarted], timeout: 1)
        let verification = browsers.browsers[1]
        XCTAssertEqual(first.cancelCount, 1)
        let finalDelay = expectSleep(.milliseconds(350), clock: clock)
        verification.emit(.waiting(policyDenied))
        await fulfillment(of: [finalDelay], timeout: 1)
        clock.wakeFirst(.milliseconds(350))
        _ = await firstRequest.value
        XCTAssertEqual(coordinator.localNetworkStatus, .denied)
        XCTAssertTrue(coordinator.localNetworkStatus.requiresLocalNetworkSettings)

        coordinator.setApplicationActive(false)
        coordinator.setApplicationActive(true)
        XCTAssertEqual(coordinator.localNetworkStatus, .denied, "Returning from Settings alone does not prove a grant")
        let recheckStarted = expectBrowser(browsers)
        let recheck = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [recheckStarted], timeout: 1)
        XCTAssertEqual(coordinator.localNetworkStatus, .requesting)
        XCTAssertFalse(coordinator.localNetworkStatus.allowsRadarInvitationSettings)
        let current = browsers.browsers[2]
        verification.emit(.ready) // A callback already queued before cancel.
        XCTAssertEqual(coordinator.localNetworkStatus, .requesting)
        current.emit(.ready)
        _ = await recheck.value
        XCTAssertEqual(coordinator.localNetworkStatus, .granted)
        verification.emit(.failed(policyDenied))
        XCTAssertEqual(coordinator.localNetworkStatus, .granted)
    }

    func testOldBrowserGenerationCannotFinishThePostPromptVerification() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        coordinator.setApplicationActive(true)
        let started = expectBrowser(browsers)
        let request = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [started], timeout: 1)
        let first = try XCTUnwrap(browsers.browsers.first)
        let delay = expectSleep(.milliseconds(600), clock: clock)
        first.emit(.waiting(policyDenied))
        await fulfillment(of: [delay], timeout: 1)
        let verificationStarted = expectBrowser(browsers)
        clock.wakeFirst(.milliseconds(600))
        await fulfillment(of: [verificationStarted], timeout: 1)
        first.emit(.ready)
        first.emit(.failed(policyDenied))
        XCTAssertEqual(coordinator.localNetworkStatus, .requesting)
        browsers.browsers[1].emit(.ready)
        _ = await request.value
        XCTAssertEqual(coordinator.localNetworkStatus, .granted)
    }

    func testCancelledRequestCannotGrantItsReplacementFromLateReadyCallback() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        let firstStarted = expectBrowser(browsers)
        let firstRequest = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let first = try XCTUnwrap(browsers.browsers.first)
        firstRequest.cancel()
        _ = await firstRequest.value
        XCTAssertEqual(coordinator.localNetworkStatus, .unavailable)
        XCTAssertEqual(first.cancelCount, 1)

        let nextStarted = expectBrowser(browsers)
        let nextRequest = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [nextStarted], timeout: 1)
        first.emit(.ready)
        XCTAssertEqual(coordinator.localNetworkStatus, .requesting)
        browsers.browsers[1].emit(.failed(policyDenied))
        _ = await nextRequest.value
        XCTAssertEqual(coordinator.localNetworkStatus, .denied)
        first.emit(.ready)
        XCTAssertEqual(coordinator.localNetworkStatus, .denied)
    }

    func testTimeoutAndTransportFailurePermitRetryWithoutClaimingPermissionDenial() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        let timeoutScheduled = expectSleep(.seconds(30), clock: clock)
        let firstRequest = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [timeoutScheduled], timeout: 1)
        clock.wakeFirst(.seconds(30))
        _ = await firstRequest.value
        XCTAssertEqual(coordinator.localNetworkStatus, .unavailable)
        XCTAssertFalse(coordinator.localNetworkStatus.requiresLocalNetworkSettings)

        let retryStarted = expectBrowser(browsers)
        let retry = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [retryStarted], timeout: 1)
        browsers.browsers[1].emit(.failed(.posix(.ENETDOWN)))
        _ = await retry.value
        XCTAssertEqual(coordinator.localNetworkStatus, .unavailable)
        let finalStarted = expectBrowser(browsers)
        let finalRequest = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [finalStarted], timeout: 1)
        browsers.browsers[2].emit(.ready)
        _ = await finalRequest.value
        XCTAssertEqual(coordinator.localNetworkStatus, .granted)
    }

    func testRecheckingCachedGrantHidesPoliciesUntilRevocationIsResolved() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        let grantedStarted = expectBrowser(browsers)
        let granted = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [grantedStarted], timeout: 1)
        browsers.browsers[0].emit(.ready)
        _ = await granted.value
        XCTAssertTrue(coordinator.localNetworkStatus.allowsRadarInvitationSettings)

        let recheckStarted = expectBrowser(browsers)
        let recheck = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [recheckStarted], timeout: 1)
        XCTAssertFalse(coordinator.localNetworkStatus.allowsRadarInvitationSettings)
        browsers.browsers[1].emit(.failed(policyDenied))
        _ = await recheck.value
        XCTAssertEqual(coordinator.localNetworkStatus, .denied)
        XCTAssertTrue(coordinator.localNetworkStatus.requiresLocalNetworkSettings)
    }

#if DEBUG
    func testRadarHasNoDirectoryOrTransportWhileLocalAccessIsUnknownOrProbing() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        let radar = RadarNearbyService(localNetworkPermissions: coordinator)
        defer { radar.configure(user: nil, allowsTransport: false) }
        let user = try radarUser()
        radar.configure(user: user)
        radar.startScanning()

        XCTAssertEqual(coordinator.localNetworkStatus, .notDetermined)
        XCTAssertFalse(radar.canDisplayDirectory)
        XCTAssertFalse(radar.hasDeniedPermission, "Unknown access is not a confirmed denial")
        XCTAssertTrue(radar.peers.isEmpty)
        XCTAssertEqual(radar.transportRebuildCountForTesting, 0)

        let started = expectBrowser(browsers)
        radar.setApplicationActive(true)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(coordinator.localNetworkStatus, .requesting)
        radar.startScanning()
        XCTAssertFalse(radar.canDisplayDirectory)
        XCTAssertEqual(radar.scanState, .idle)
        XCTAssertTrue(radar.peers.isEmpty)
        XCTAssertEqual(radar.transportRebuildCountForTesting, 0)
        XCTAssertEqual(radar.browserStartCountForTesting, 0)

        browsers.browsers[0].emit(.failed(.posix(.ENETDOWN)))
        await waitForStatus(.unavailable, coordinator: coordinator)
        XCTAssertFalse(radar.canDisplayDirectory)
        XCTAssertFalse(radar.hasDeniedPermission)
    }

    func testRevokedLocalAccessClearsVisiblePeersInvitationsAndBlocksTransport() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        let grantedStarted = expectBrowser(browsers)
        let grant = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [grantedStarted], timeout: 1)
        browsers.browsers[0].emit(.ready)
        _ = await grant.value

        let radar = RadarNearbyService(localNetworkPermissions: coordinator)
        defer { radar.configure(user: nil, allowsTransport: false) }
        radar.configure(user: try radarUser())
        radar.installPreviewRangingPeers()
        let peer = try XCTUnwrap(radar.peers.first)
        radar.presentForConfirmation(RadarIncomingInvitation(
            roomCode: "ABC123", hostCallSign: "Host", hostAvatar: "🕵️"
        ))
        XCTAssertTrue(radar.canDisplayDirectory)
        XCTAssertFalse(radar.peers.isEmpty)
        XCTAssertNotNil(radar.incomingInvitation)

        let started = expectBrowser(browsers)
        let recheck = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(radar.canDisplayDirectory)
        XCTAssertTrue(radar.peers.isEmpty, "A cached directory must disappear during revalidation")
        XCTAssertNil(radar.incomingInvitation)
        browsers.browsers[1].emit(.failed(policyDenied))
        _ = await recheck.value

        XCTAssertTrue(radar.hasDeniedPermission)
        radar.startScanning()
        radar.refreshTransportAfterLocalNetworkGrant()
        XCTAssertFalse(radar.canDisplayDirectory)
        XCTAssertTrue(radar.peers.isEmpty)
        XCTAssertEqual(radar.scanState, .idle)
        XCTAssertEqual(radar.transportRebuildCountForTesting, 0)
        let dispatch = await radar.toggleInvitation(peer, to: .previewRoom(status: "waiting"))
        XCTAssertEqual(dispatch, .unavailable)

        // A callback queued by the browser from the earlier grant cannot
        // restore the directory or transport after that grant was revoked.
        browsers.browsers[0].emit(.ready)
        XCTAssertEqual(coordinator.localNetworkStatus, .denied)
        XCTAssertFalse(radar.canDisplayDirectory)
        XCTAssertEqual(radar.transportRebuildCountForTesting, 0)
    }

    func testForegroundRecoveryRequiresFreshGrantBeforeResumingRequestedRadarScan() async throws {
        let browsers = PermissionBrowserHarness()
        let clock = PermissionTestClock()
        defer { clock.wakeAll() }
        let coordinator = makeCoordinator(browsers, clock)
        let deniedStarted = expectBrowser(browsers)
        let denied = Task { await coordinator.request(.nearby) }
        await fulfillment(of: [deniedStarted], timeout: 1)
        browsers.browsers[0].emit(.failed(policyDenied))
        _ = await denied.value

        let radar = RadarNearbyService(localNetworkPermissions: coordinator)
        defer { radar.configure(user: nil, allowsTransport: false) }
        radar.configure(user: try radarUser())
        radar.startScanning()
        XCTAssertTrue(radar.hasDeniedPermission)
        XCTAssertFalse(radar.canDisplayDirectory)

        let recheckStarted = expectBrowser(browsers)
        radar.setApplicationActive(true)
        await fulfillment(of: [recheckStarted], timeout: 1)
        XCTAssertEqual(coordinator.localNetworkStatus, .requesting)
        XCTAssertFalse(radar.canDisplayDirectory)
        XCTAssertEqual(radar.transportRebuildCountForTesting, 0)
        browsers.browsers[1].emit(.ready)
        await waitForStatus(.granted, coordinator: coordinator)

        XCTAssertTrue(radar.canDisplayDirectory)
        XCTAssertFalse(radar.hasDeniedPermission)
        XCTAssertEqual(radar.scanState, .scanning)
        XCTAssertEqual(radar.transportRebuildCountForTesting, 1)
        XCTAssertEqual(radar.browserStartCountForTesting, 1)
    }

    private func radarUser() throws -> SpyUser {
        try JSONDecoder().decode(
            SpyUser.self,
            from: Data(#"{"id":"permission-radar-user","email":"permission-radar@example.invalid"}"#.utf8)
        )
    }

    private func waitForStatus(
        _ status: OnboardingPermissionStatus,
        coordinator: OnboardingPermissionCoordinator
    ) async {
        let resolved = expectation(description: "Local permission resolves to \(status)")
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                if coordinator.localNetworkStatus == status {
                    resolved.fulfill()
                    return
                }
                await Task.yield()
            }
        }
        await fulfillment(of: [resolved], timeout: 1)
        observer.cancel()
    }
#endif
}

@MainActor
private final class PermissionBrowserHarness {
    var browsers: [PermissionFixtureBrowser] = []
    var onNextStart: (() -> Void)?

    func makeBrowser() -> any LocalNetworkPermissionBrowser {
        let browser = PermissionFixtureBrowser { [weak self] in
            let callback = self?.onNextStart
            self?.onNextStart = nil
            callback?()
        }
        browsers.append(browser)
        return browser
    }
}

@MainActor
private final class PermissionFixtureBrowser: LocalNetworkPermissionBrowser {
    private let onStart: () -> Void
    private var callback: (@MainActor @Sendable (NWBrowser.State) -> Void)?
    private(set) var cancelCount = 0

    init(onStart: @escaping () -> Void) { self.onStart = onStart }
    func start(onStateChange: @escaping @MainActor @Sendable (NWBrowser.State) -> Void) {
        callback = onStateChange
        onStart()
    }
    func cancel() { cancelCount += 1 }
    // Retain the callback after cancel to emulate an already queued event.
    func emit(_ state: NWBrowser.State) { callback?(state) }
}

@MainActor
private final class PermissionTestClock {
    private var sleepers: [(Duration, CheckedContinuation<Void, Never>)] = []
    private var observers: [(Duration, () -> Void)] = []

    func onNextSleep(_ duration: Duration, perform: @escaping () -> Void) {
        observers.append((duration, perform))
    }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        await withCheckedContinuation { continuation in
            sleepers.append((duration, continuation))
            if let index = observers.firstIndex(where: { $0.0 == duration }) {
                observers.remove(at: index).1()
            }
        }
        try Task.checkCancellation()
    }

    func wakeFirst(_ duration: Duration) {
        guard let index = sleepers.firstIndex(where: { $0.0 == duration }) else {
            XCTFail("No scheduled permission delay: \(duration)")
            return
        }
        sleepers.remove(at: index).1.resume()
    }

    func wakeAll() {
        let pending = sleepers
        sleepers.removeAll()
        for (_, continuation) in pending { continuation.resume() }
    }
}
