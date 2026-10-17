import Foundation
import Network
import WebKit
import XCTest
@testable import SpyClash

/// These fixtures execute in the real WebKit process, using an injected initial
/// HTML document. Navigation still goes through the production delegate and
/// trust policy; no production endpoint or real credential is contacted.
@MainActor
final class AppleSessionCompletionWebKitTests: XCTestCase {
    private let bootstrapURL = URL(string: "https://spyclash.com/functions/appleAuthBroker?action=native-bootstrap&ticket=synthetic-webkit-ticket")!

    func testAllOptionalPolicyDelegatesAreExposedToObjectiveC() {
        let fixture = AppleWebKitFixture(script: "")
        let session = fixture.session(url: bootstrapURL) {}
        for selector in appleWebKitRequiredDelegateSelectors {
            XCTAssertTrue(session.responds(to: NSSelectorFromString(selector)), selector)
        }
    }

    func testJavaScriptCompletesNativeSessionWithoutPresentingAView() async throws {
        let terminal = expectation(description: "JavaScript callback completes")
        let fixture = AppleWebKitFixture(script: "window.location.replace('spyclash://auth?auth_provider=apple&access_token=synthetic-js-session');")
        let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }

        XCTAssertTrue(session.start())
        let view = try XCTUnwrap(fixture.webView)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(view.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertNil(view.superview)
        XCTAssertNil(view.window)

        await fulfillment(of: [terminal], timeout: 15)
        XCTAssertNil(fixture.error)
        XCTAssertEqual(try AppleNativeHandoffPolicy.browserAccessToken(from: XCTUnwrap(fixture.callback)), "synthetic-js-session")
        XCTAssertEqual(fixture.completionCount, 1)
        XCTAssertEqual(fixture.initialLoadCount, 1)
        await assertCleanedUp(view)
        session.cancel()
        XCTAssertEqual(fixture.completionCount, 1)
    }

    func testCanonicalHTTPSCallbackIsInterceptedBeforeLoadingPage() async throws {
        let terminal = expectation(description: "HTTPS callback is intercepted")
        let target = "https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple&access_token=synthetic-https-session"
        let fixture = AppleWebKitFixture(script: "window.location.replace(\(jsString(target)));")
        let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }

        XCTAssertTrue(session.start())
        let view = try XCTUnwrap(fixture.webView)
        await fulfillment(of: [terminal], timeout: 15)

        XCTAssertNil(fixture.error)
        XCTAssertEqual(try AppleNativeHandoffPolicy.sessionAccessToken(from: XCTUnwrap(fixture.callback)), "synthetic-https-session")
        XCTAssertNotEqual(view.url?.path, AppleNativeHandoffPolicy.callbackPath)
        await assertCleanedUp(view)
    }

    func testJavaScriptCannotCompleteWithMalformedOrWrongProviderCallbacks() async throws {
        let rejected = [
            "spyclash://auth?access_token=synthetic-unmarked",
            "spyclash://auth?auth_provider=google&access_token=synthetic-google",
            "spyclash://auth?auth_provider=apple&access_token=first&access_token=second",
            "spyclash://auth?auth_provider=apple&access_token=synthetic&error=access_denied",
            "spyclash://auth/other?auth_provider=apple&access_token=synthetic-path",
            "https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple&access_token=synthetic#access_token=other"
        ]
        for target in rejected {
            let terminal = expectation(description: "Malformed callback rejected")
            let fixture = AppleWebKitFixture(script: "window.location.replace(\(jsString(target)));")
            let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
            XCTAssertTrue(session.start())
            await fulfillment(of: [terminal], timeout: 15)
            XCTAssertNil(fixture.callback)
            XCTAssertNotNil(fixture.error)
            XCTAssertEqual(fixture.completionCount, 1)
            await assertCleanedUp(try XCTUnwrap(fixture.webView))
        }
    }

    func testInteractiveProviderAndForeignNavigationsAreBlocked() async throws {
        let rejected = [
            "https://appleid.apple.com/auth/authorize?client_id=synthetic",
            "https://spyclash.com/login",
            "https://app.base44.com/login",
            "https://foreign.invalid/steal?ticket=synthetic",
            "https://spyclash.com.evil.invalid/functions/appleAuthBroker?action=authorize"
        ]
        for target in rejected {
            let terminal = expectation(description: "Interactive or foreign navigation blocked")
            let fixture = AppleWebKitFixture(script: "window.location.replace(\(jsString(target)));")
            let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
            XCTAssertTrue(session.start())
            let view = try XCTUnwrap(fixture.webView)
            await fulfillment(of: [terminal], timeout: 15)
            XCTAssertNil(fixture.callback)
            XCTAssertNotNil(fixture.error)
            XCTAssertNotEqual(view.url?.absoluteString, target)
            await assertCleanedUp(view)
        }
    }

    func testUntrustedBootstrapNeverCreatesOrLoadsWebKit() {
        let fixture = AppleWebKitFixture(script: "throw new Error('must not execute');")
        let session = fixture.session(url: URL(string: "https://foreign.invalid/?ticket=synthetic")!) {}
        _ = session.start()
        XCTAssertNil(fixture.webView)
        XCTAssertEqual(fixture.initialLoadCount, 0)
        XCTAssertNil(fixture.callback)
    }

    func testTrustedDocumentCannotAskForInteractiveCredentials() async throws {
        let terminal = expectation(description: "Interactive document is rejected")
        let fixture = AppleWebKitFixture(script: "document.body.innerHTML = '<form><input type=password><button>Sign in</button></form>';")
        let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
        XCTAssertTrue(session.start())
        await fulfillment(of: [terminal], timeout: 15)
        XCTAssertNil(fixture.callback)
        XCTAssertNotNil(fixture.error)
        await assertCleanedUp(try XCTUnwrap(fixture.webView))
    }

    func testSubframeCannotCompleteTheMainAppleAttempt() async throws {
        let terminal = expectation(description: "Subframe callback is rejected")
        let fixture = AppleWebKitFixture(script: "const frame = document.createElement('iframe'); frame.src = 'spyclash://auth?auth_provider=apple&access_token=synthetic-subframe'; document.body.appendChild(frame);")
        let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
        XCTAssertTrue(session.start())
        await fulfillment(of: [terminal], timeout: 15)
        XCTAssertNil(fixture.callback)
        XCTAssertNotNil(fixture.error)
        await assertCleanedUp(try XCTUnwrap(fixture.webView))
    }

    func testRealWebKitCookieStoreIsPrivateToOneAttempt() async throws {
        let firstReady = expectation(description: "First document executed")
        let first = AppleWebKitFixture(script: "document.cookie = 'sc_fixture_cookie=attempt-one; Path=/; Secure; SameSite=Lax'; window.webkit.messageHandlers.fixtureReady.postMessage(document.cookie);")
        first.onMessage = { _ in firstReady.fulfill() }
        let firstSession = first.session(url: bootstrapURL) { XCTFail("Cookie fixture has no auth callback") }
        XCTAssertTrue(firstSession.start())
        await fulfillment(of: [firstReady], timeout: 15)
        let firstView = try XCTUnwrap(first.webView)
        XCTAssertTrue(first.lastMessage?.contains("sc_fixture_cookie=attempt-one") == true)
        let firstCookies = await firstView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertEqual(firstCookies.first(where: { $0.name == "sc_fixture_cookie" })?.value, "attempt-one")

        let httpOnly = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "spyclash.com", .path: "/", .name: "sc_fixture_http_only", .value: "synthetic-private",
            .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE"
        ]))
        await firstView.configuration.websiteDataStore.httpCookieStore.setCookie(httpOnly)
        let visibleCookies = try await firstView.evaluateJavaScript("document.cookie") as? String
        XCTAssertFalse(visibleCookies?.contains("synthetic-private") == true)
        let stored = await firstView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(stored.contains(where: { $0.name == "sc_fixture_http_only" && $0.isHTTPOnly }))

        let secondReady = expectation(description: "Second document executed")
        let second = AppleWebKitFixture(script: "window.webkit.messageHandlers.fixtureReady.postMessage(document.cookie);")
        second.onMessage = { _ in secondReady.fulfill() }
        let secondSession = second.session(url: bootstrapURL) { XCTFail("Cookie fixture has no auth callback") }
        XCTAssertTrue(secondSession.start())
        await fulfillment(of: [secondReady], timeout: 15)
        let secondView = try XCTUnwrap(second.webView)
        XCTAssertFalse(secondView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(firstView.configuration.websiteDataStore === secondView.configuration.websiteDataStore)
        XCTAssertFalse(second.lastMessage?.contains("sc_fixture_cookie") == true)
        let secondCookies = await secondView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertFalse(secondCookies.contains(where: { $0.name.hasPrefix("sc_fixture_") }))
        firstSession.cancel()
        secondSession.cancel()
        await assertCleanedUp(firstView)
        await assertCleanedUp(secondView)
    }

    func testCancellationClearsRealWebKitAndIgnoresRetainedLateDelegateEvents() async throws {
        let ready = expectation(description: "JavaScript is running before cancellation")
        let fixture = AppleWebKitFixture(script: "window.webkit.messageHandlers.fixtureReady.postMessage('ready');")
        fixture.onMessage = { _ in ready.fulfill() }
        let session = fixture.session(url: bootstrapURL) {}
        XCTAssertTrue(session.start())
        await fulfillment(of: [ready], timeout: 15)
        let view = try XCTUnwrap(fixture.webView)
        let lateDelegate = try XCTUnwrap(view.navigationDelegate)

        session.cancel()
        await assertCleanedUp(view)
        let countAfterCancel = fixture.completionCount
        lateDelegate.webView?(view, didFail: nil, withError: URLError(.networkConnectionLost))
        lateDelegate.webView?(view, didFailProvisionalNavigation: nil, withError: URLError(.cancelled))
        lateDelegate.webView?(view, didFinish: nil)
        await Task.yield()

        XCTAssertNil(fixture.callback)
        XCTAssertEqual(fixture.completionCount, countAfterCancel)
        XCTAssertFalse(session.start(), "A cancelled session cannot resume its old ticket")
    }

    func testCancellationBeforeStartDoesNotCreateAWebView() {
        let fixture = AppleWebKitFixture(script: "window.location.replace('spyclash://auth?auth_provider=apple&access_token=late');")
        let session = fixture.session(url: bootstrapURL) {}
        session.cancel()
        XCTAssertFalse(session.start())
        XCTAssertNil(fixture.webView)
        XCTAssertEqual(fixture.initialLoadCount, 0)
        XCTAssertNil(fixture.callback)
    }

    func testCoordinatorDeadlineCleansUpRealWebKit() async throws {
        let fixture = AppleWebKitFixture(script: "window.webkit.messageHandlers.fixtureReady.postMessage('waiting');")
        let coordinator = WebAuthenticationCoordinator(makeSession: { url, completion in
            fixture.session(url: url, completion: completion)
        })
        do {
            _ = try await coordinator.authenticate(url: bootstrapURL, timeout: 0.25)
            XCTFail("A document with no callback must expire")
        } catch let error as WebAuthenticationError {
            XCTAssertEqual(error, .expired)
        }
        await assertCleanedUp(try XCTUnwrap(fixture.webView))
        XCTAssertNil(fixture.callback)
    }

    private func assertCleanedUp(_ view: WKWebView, file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertNil(view.navigationDelegate, file: file, line: line)
        XCTAssertNil(view.uiDelegate, file: file, line: line)
        XCTAssertNil(view.superview, file: file, line: line)
        XCTAssertNil(view.window, file: file, line: line)
        // stopLoading updates WebKit process state asynchronously. Delegate
        // ownership must clear immediately; loading may settle on the next turn.
        let stopDeadline = Date().addingTimeInterval(2)
        while view.isLoading && Date() < stopDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(view.isLoading, file: file, line: line)
    }

    private func jsString(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
    }
}

@MainActor
private final class AppleWebKitFixture: NSObject, WKScriptMessageHandler {
    let script: String
    var webView: WKWebView?
    var initialLoadCount = 0
    var completionCount = 0
    var callback: URL?
    var error: (any Error)?
    var lastMessage: String?
    var onMessage: (@MainActor (String?) -> Void)?

    init(script: String) { self.script = script }

    func session(url: URL, onCompletion: @escaping @MainActor () -> Void) -> AppleSessionCompletionSession {
        session(url: url) { [weak self] callback, error in
            self?.completionCount += 1
            self?.callback = callback
            self?.error = error
            onCompletion()
        }
    }

    func session(url: URL, completion: @escaping WebAuthenticationCoordinator.Completion) -> AppleSessionCompletionSession {
        AppleSessionCompletionSession(url: url, completion: completion, makeWebView: { [weak self] configuration in
            guard let self else { fatalError("Fixture must outlive its session") }
            // A policy regression must fail locally rather than fetch an Apple
            // or application page. HTML is injected; all real HTTP(S) traffic
            // is fenced to an unusable loopback proxy, with no direct fallback.
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: 9))
            proxy.allowFailover = false
            configuration.websiteDataStore.proxyConfigurations = [proxy]
            configuration.userContentController.add(AppleWebKitWeakMessageHandler(target: self), name: "fixtureReady")
            let view = WKWebView(frame: .zero, configuration: configuration)
            self.webView = view
            return view
        }, loadRequest: { [weak self] view, request in
            guard let self else { return }
            self.initialLoadCount += 1
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            // Swift 6 optional ObjC delegate methods can compile as near matches
            // while silently skipping their runtime policy. Fail before loading.
            guard appleWebKitRequiredDelegateSelectors.allSatisfy({
                view.navigationDelegate?.responds(to: NSSelectorFromString($0)) == true
            }) else {
                XCTFail("The real WebKit policy delegate is missing an Objective-C selector")
                return
            }
            let html = "<!doctype html><html><head><meta name='referrer' content='no-referrer'></head><body><script>\(self.script)</script></body></html>"
            view.loadHTMLString(html, baseURL: request.url)
        })
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        lastMessage = message.body as? String
        onMessage?(lastMessage)
    }
}

private let appleWebKitRequiredDelegateSelectors = [
    "webView:decidePolicyForNavigationAction:decisionHandler:",
    "webView:decidePolicyForNavigationResponse:decisionHandler:",
    "webView:didReceiveAuthenticationChallenge:completionHandler:",
    "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
    "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
    "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
    "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
    "webView:requestDeviceOrientationAndMotionPermissionForOrigin:initiatedByFrame:decisionHandler:"
]

@MainActor
private final class AppleWebKitWeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: AppleWebKitFixture?

    init(target: AppleWebKitFixture) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private extension WKHTTPCookieStore {
    @MainActor
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
