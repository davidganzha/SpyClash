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
