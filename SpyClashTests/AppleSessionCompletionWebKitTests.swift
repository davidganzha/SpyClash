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

    func testSSOCandidateIsInterceptedOnlyAfterOwnedMainSequenceWithoutRendering() async throws {
        for host in ["spyclash.com", "app.base44.com"] {
            let terminal = expectation(description: "Owned SSO returns an unverified candidate")
            let target = "https://\(host)/synthetic-intermediate?access_token=synthetic-sso-candidate&from_url=https%3A%2F%2Fforeign.invalid"
            let fixture = ssoFixture(finalScript: "window.location.replace(\(jsString(target)));")
            let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
            XCTAssertTrue(session.start())
            let view = try XCTUnwrap(fixture.webView)
            await fulfillment(of: [terminal], timeout: 15)
            XCTAssertNil(fixture.error)
            let callback = try XCTUnwrap(fixture.callback)
            XCTAssertEqual(try AppleNativeHandoffPolicy.sessionAccessToken(from: callback), "synthetic-sso-candidate")
            XCTAssertFalse(callback.absoluteString.contains("from_url"))
            XCTAssertFalse(callback.absoluteString.contains("foreign.invalid"))
            XCTAssertNotEqual(view.url?.path, "/synthetic-intermediate")
            XCTAssertEqual(fixture.completionCount, 1)
            await assertCleanedUp(view)
        }
    }

    /// Runs only with the local TLS fixture and a disposable Simulator trust
    /// store. Unlike injected HTML, this exercises real HTTPS server redirects
    /// and the production authentication-challenge delegate without overrides.
    func testRealHTTPSRedirectsInterceptCandidateBeforeNetworkRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let proxyValue = environment["SPYCLASH_TEST_TLS_PROXY_PORT"],
              let reportValue = environment["SPYCLASH_TEST_TLS_REPORT_PORT"] else {
            throw XCTSkip("Requires scripts/tests/fixtures/apple_sso_https_fixture.py in a disposable Simulator")
        }
        let proxyPort = try XCTUnwrap(UInt16(proxyValue))
        let reportPort = try XCTUnwrap(UInt16(reportValue))
        XCTAssertGreaterThan(proxyPort, 0)
        XCTAssertGreaterThan(reportPort, 0)
        let reportURL = URL(string: "http://127.0.0.1:\(reportPort)/report")!
        let (initialData, _) = try await URLSession.shared.data(from: reportURL)
        let initial = try XCTUnwrap(JSONSerialization.jsonObject(with: initialData) as? [String: Any])
        XCTAssertEqual(initial["fixture"] as? String, "apple-native-https-fixture")
        XCTAssertEqual(initial["request_count"] as? Int, 0, "Start a fresh fixture for each run")

        let terminal = expectation(description: "Real TLS SSO chain yields a candidate")
        var callback: URL?
        var failure: (any Error)?
        var view: WKWebView?
        var completions = 0
        let session = AppleSessionCompletionSession(url: bootstrapURL, completion: { url, error in
            callback = url
            failure = error
            completions += 1
            terminal.fulfill()
        }, makeWebView: { configuration in
            var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: proxyPort)!))
            proxy.allowFailover = false
            configuration.websiteDataStore.proxyConfigurations = [proxy]
            let result = WKWebView(frame: .zero, configuration: configuration)
            view = result
            return result
        })
        XCTAssertTrue(session.start())
        await fulfillment(of: [terminal], timeout: 30)
        XCTAssertNil(failure)
        XCTAssertEqual(try AppleNativeHandoffPolicy.sessionAccessToken(from: XCTUnwrap(callback)), "synthetic-https-candidate-186")
        XCTAssertEqual(completions, 1)
        await assertCleanedUp(try XCTUnwrap(view))

        let (data, _) = try await URLSession.shared.data(from: reportURL)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["request_count"] as? Int, 5)
        XCTAssertEqual(report["final_route_fetches"] as? Int, 0)
        let requests = try XCTUnwrap(report["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.compactMap { $0["category"] as? String }, [
            "bootstrap", "spyclash_sso_login", "base44_sso_login", "broker_authorize", "base44_sso_callback"
        ])
        XCTAssertTrue(requests.allSatisfy { $0["method"] as? String == "GET" })
        let events = try XCTUnwrap(report["events"] as? [String: Int])
        XCTAssertNil(events["tls_error"])
        XCTAssertNil(events["rejected_connect"])
    }

    func testCandidateCannotSkipReorderOrResumeAfterLeavingSSOSequence() async throws {
        let route = "https://app.base44.com/api/apps/69a0e57fa939f578082f8091/auth/sso/"
        let authorize = "https://spyclash.com/functions/appleAuthBroker?action=authorize&state=synthetic"
        let callback = route + "callback?code=synthetic&state=synthetic"
        let target = "https://spyclash.com/synthetic-intermediate?access_token=synthetic-not-owned&is_new_user=false"
        let finalScript = "window.location.replace(\(jsString(target)));"
        for stages in [[], [callback], [authorize, route + "login", callback], [route + "login", authorize, callback, authorize]] {
            let terminal = expectation(description: "Candidate with missing or lost SSO ownership is rejected")
            let fixture = ssoFixture(finalScript: finalScript, stages: stages)
            let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
            XCTAssertTrue(session.start())
            await fulfillment(of: [terminal], timeout: 15)
            XCTAssertNil(fixture.callback)
            XCTAssertEqual((fixture.error as? AppleNativeHandoffError)?.supportCode, .navigationDocument)
            XCTAssertEqual(fixture.completionCount, 1)
            await assertCleanedUp(try XCTUnwrap(fixture.webView))
        }
    }

    func testSSOCandidateStillRejectsForeignProviderAndPostNavigation() async throws {
        let cases: [(String, AppleNativeHandoffFailureCode)] = [
            ("window.location.replace('https://foreign.invalid/landing?access_token=synthetic');", .callbackOrigin),
            ("window.location.replace('https://spyclash.com/landing?access_token=synthetic&auth_provider=google');", .callbackProvider),
            ("const f=document.createElement('form'); f.method='POST'; f.action='https://spyclash.com/landing?access_token=synthetic'; document.body.appendChild(f); f.submit(); f.remove();", .navigationMethod),
        ]
        for (script, code) in cases {
            let terminal = expectation(description: "Malformed candidate is not accepted")
            let fixture = ssoFixture(finalScript: script)
            let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
            XCTAssertTrue(session.start())
            await fulfillment(of: [terminal], timeout: 15)
            XCTAssertNil(fixture.callback)
            XCTAssertEqual((fixture.error as? AppleNativeHandoffError)?.supportCode, code)
            XCTAssertEqual(fixture.completionCount, 1)
            await assertCleanedUp(try XCTUnwrap(fixture.webView))
        }
    }

    func testSSOCandidateInChildFrameCannotCompleteMainAttempt() async throws {
        let terminal = expectation(description: "Only the later main candidate completes")
        let fixture = ssoFixture(finalScript: """
            const frame=document.createElement('iframe');
            frame.src='https://spyclash.com/landing?access_token=synthetic-child';
            document.body.appendChild(frame);
            setTimeout(() => {
                window.webkit.messageHandlers.fixtureReady.postMessage('before-main');
                window.location.replace('https://spyclash.com/landing?access_token=synthetic-main');
            }, 200);
            """)
        let previous = fixture.onMessage
        var reachedMain = false
        fixture.onMessage = { [weak fixture] message in
            if message == "before-main" {
                reachedMain = true
                XCTAssertEqual(fixture?.completionCount, 0)
            } else { previous?(message) }
        }
        let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
        XCTAssertTrue(session.start())
        await fulfillment(of: [terminal], timeout: 15)
        XCTAssertTrue(reachedMain)
        XCTAssertNil(fixture.error)
        XCTAssertEqual(try AppleNativeHandoffPolicy.sessionAccessToken(from: XCTUnwrap(fixture.callback)), "synthetic-main")
        XCTAssertEqual(fixture.completionCount, 1)
        await assertCleanedUp(try XCTUnwrap(fixture.webView))
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
            ("Apple provider", "https://appleid.apple.com/auth/authorize?client_id=synthetic"),
            ("SpyClash login", "https://spyclash.com/login"),
            ("Base44 login", "https://app.base44.com/login"),
            ("Foreign host", "https://foreign.invalid/steal?ticket=synthetic"),
            ("Lookalike host", "https://spyclash.com.evil.invalid/functions/appleAuthBroker?action=authorize")
        ]
        for (scenario, target) in rejected {
            let ready = expectation(description: "\(scenario): fixture document loaded")
            let terminal = expectation(description: "\(scenario): navigation rejected by policy")
            let fixture = AppleWebKitFixture(script: """
                window.addEventListener('load', () => {
                    window.webkit.messageHandlers.fixtureReady.postMessage('navigation-document-ready');
                }, { once: true });
                """)
            fixture.onMessage = { message in
                if message == "navigation-document-ready" { ready.fulfill() }
            }
            let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
            defer { session.cancel(); fixture.onMessage = nil }
            XCTAssertTrue(session.start())
            let view = try XCTUnwrap(fixture.webView)

            // A cold CI WebContent process has taken over 23 seconds to start.
            // Establish document readiness separately so policy timing measures
            // the rejected navigation, and a startup failure cannot pass as one.
            await fulfillment(of: [ready], timeout: 45)
            guard fixture.lastMessage == "navigation-document-ready" else { return }
            XCTAssertEqual(fixture.completionCount, 0, scenario)
            XCTAssertNil(fixture.error, scenario)
            _ = try await view.evaluateJavaScript("window.location.replace(\(jsString(target))); null;")
            await fulfillment(of: [terminal], timeout: 15)
            XCTAssertNil(fixture.callback, scenario)
            XCTAssertEqual((fixture.error as? AppleNativeHandoffError)?.supportCode, .navigationDocument, scenario)
            XCTAssertEqual(fixture.completionCount, 1, scenario)
            XCTAssertNotEqual(view.url?.absoluteString, target, scenario)
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

    func testIncidentalFramesDoNotTerminateTheMainAppleAttempt() async throws {
        for frameURL in ["about:blank", "https://foreign.invalid/incidental-auth-frame"] {
            try await assertFrameCannotCompleteOrTerminateMainAttempt(frameURL: frameURL)
        }
    }

    func testSubframeCannotCompleteTheMainAppleAttempt() async throws {
        for frameURL in [
            "spyclash://auth?auth_provider=apple&access_token=synthetic-subframe-only",
            "https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple&access_token=synthetic-subframe-only"
        ] {
            try await assertFrameCannotCompleteOrTerminateMainAttempt(frameURL: frameURL)
        }
    }

    func testRejectedNavigationActionsRetainOnlyBoundedDiagnostics() async throws {
        let secret = "synthetic-private-diagnostic-value"
        let postURL = "https://spyclash.com/functions/appleAuthBroker?action=native-bootstrap&ticket=\(secret)"
        let popupURL = "https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple&access_token=\(secret)"
        let cases: [(script: String, enablesPopupFixture: Bool, code: AppleNativeHandoffFailureCode, suffix: String)] = [
            ("window.location.replace(\(jsString("https://foreign.invalid/private-path?private_query=\(secret)")));", false,
             .navigationDocument, "-s0-cN-uUN-q10-pN-fN"),
            ("const form = document.createElement('form'); form.method = 'POST'; form.action = \(jsString(postURL)); document.body.appendChild(form); form.submit(); form.remove();", false,
             .navigationMethod, "-s0-cN-uNB-q10-pN-fN"),
            ("window.open(\(jsString(popupURL)), '_blank');", true,
             .navigationPopup, "-s0-cN-uAC-q3-pA-fN")
        ]
        for item in cases {
            let terminal = expectation(description: "Actual WebKit action is rejected")
            let fixture = AppleWebKitFixture(script: item.script, enablesPopupFixture: item.enablesPopupFixture)
            let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
            XCTAssertTrue(session.start())
            await fulfillment(of: [terminal], timeout: 15)
            let view = try XCTUnwrap(fixture.webView)
            XCTAssertNil(fixture.callback)
            XCTAssertEqual(fixture.completionCount, 1)
            try assertBoundedDiagnostic(fixture.error, code: item.code, suffix: item.suffix, secret: secret)
            await assertCleanedUp(view)
        }
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
        let ready = expectation(description: "Real WebKit document is waiting for authentication")
        let fixture = AppleWebKitFixture(script: "window.webkit.messageHandlers.fixtureReady.postMessage('waiting');")
        fixture.onMessage = { _ in ready.fulfill() }
        let timer = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var currentTime = Date()
        let coordinator = WebAuthenticationCoordinator(makeSession: { url, completion in
            fixture.session(url: url, completion: completion)
        }, now: { currentTime }, sleep: { _ in
            for await _ in timer.stream { return }
        })
        let authentication = Task { try await coordinator.authenticate(url: bootstrapURL, timeout: 90) }
        defer { timer.continuation.finish(); authentication.cancel() }
        await fulfillment(of: [ready], timeout: 15)
        let view = try XCTUnwrap(fixture.webView)
        // A 250ms real timer raced cold WebKit process startup. Advance the
        // injected deadline only once an actual loaded document is waiting;
        // expiry must still cancel its session and satisfy every cleanup check.
        let loadDeadline = Date().addingTimeInterval(2)
        while view.isLoading && Date() < loadDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(view.isLoading)
        XCTAssertNotNil(view.navigationDelegate)
        currentTime.addTimeInterval(91)
        timer.continuation.yield(())
        do {
            _ = try await authentication.value
            XCTFail("A document with no callback must expire")
        } catch let error as WebAuthenticationError {
            XCTAssertEqual(error, .expired)
        }
        await assertCleanedUp(view)
        XCTAssertNil(fixture.callback)
    }

    private func assertBoundedDiagnostic(
        _ error: (any Error)?,
        code: AppleNativeHandoffFailureCode,
        suffix: String,
        secret: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let failure = try XCTUnwrap(error as? AppleNativeHandoffError, file: file, line: line)
        XCTAssertEqual(failure.supportCode, code, file: file, line: line)
        guard case .diagnosed(_, let diagnostic) = failure else {
            XCTFail("The failure must preserve bounded navigation context", file: file, line: line)
            return
        }
        XCTAssertTrue((0...13).contains(diagnostic.redirectCount), file: file, line: line)
        XCTAssertEqual(failure.diagnosticIdentifier, "SCA177-\(code.rawValue)-r\(diagnostic.redirectCount)\(suffix)", file: file, line: line)
        for representation in [failure.diagnosticIdentifier, failure.localizedDescription, String(reflecting: failure)] {
            for forbidden in [secret, "foreign.invalid", "spyclash.com", "private-path", "private_query", "X-Private-Fixture"] {
                XCTAssertFalse(representation.contains(forbidden), "Diagnostic must exclude private input", file: file, line: line)
            }
        }
    }

    private func assertFrameCannotCompleteOrTerminateMainAttempt(
        frameURL: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let terminal = expectation(description: "Only the later main-frame callback completes")
        let fixture = AppleWebKitFixture(script: """
            const frame = document.createElement('iframe');
            frame.src = \(jsString(frameURL));
            document.body.appendChild(frame);
            setTimeout(() => {
                window.webkit.messageHandlers.fixtureReady.postMessage('main-callback-ready');
                window.location.replace('spyclash://auth?auth_provider=apple&access_token=synthetic-main-after-frame');
            }, 200);
            """)
        var mainCallbackWasReached = false
        fixture.onMessage = { [weak fixture] message in
            guard message == "main-callback-ready", let fixture else { return }
            mainCallbackWasReached = true
            XCTAssertEqual(fixture.completionCount, 0, "The incidental frame must not complete or fail authentication", file: file, line: line)
            XCTAssertNil(fixture.callback, file: file, line: line)
            XCTAssertNil(fixture.error, file: file, line: line)
            XCTAssertNil(fixture.webView?.superview, file: file, line: line)
            XCTAssertNil(fixture.webView?.window, file: file, line: line)
        }
        let session = fixture.session(url: bootstrapURL) { terminal.fulfill() }
        XCTAssertTrue(session.start(), file: file, line: line)
        let view = try XCTUnwrap(fixture.webView, file: file, line: line)
        XCTAssertNil(view.superview, file: file, line: line)
        XCTAssertNil(view.window, file: file, line: line)

        await fulfillment(of: [terminal], timeout: 15)

        XCTAssertTrue(mainCallbackWasReached, "The main document must survive until its own callback", file: file, line: line)
        XCTAssertNil(fixture.error, file: file, line: line)
        XCTAssertEqual(
            try AppleNativeHandoffPolicy.sessionAccessToken(from: XCTUnwrap(fixture.callback, file: file, line: line)),
            "synthetic-main-after-frame", file: file, line: line
        )
        XCTAssertEqual(fixture.completionCount, 1, file: file, line: line)
        XCTAssertEqual(fixture.initialLoadCount, 1, file: file, line: line)
        await assertCleanedUp(view, file: file, line: line)
        session.cancel()
        XCTAssertEqual(fixture.completionCount, 1, file: file, line: line)
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

    /// Inject successive documents at the actual permitted route shapes. Every
    /// load still traverses WebKit's real main-frame policy; the loopback-only
    /// proxy guarantees no fixture can contact a provider or production host.
    private func ssoFixture(finalScript: String, stages: [String]? = nil) -> AppleWebKitFixture {
        let appRoute = "/api/apps/69a0e57fa939f578082f8091/auth/sso/"
        let stages = stages ?? [
            "https://spyclash.com" + appRoute + "login?app_id=69a0e57fa939f578082f8091",
            "https://app.base44.com" + appRoute + "login?app_id=69a0e57fa939f578082f8091",
            "https://spyclash.com/functions/appleAuthBroker?action=authorize&state=synthetic",
            "https://app.base44.com" + appRoute + "callback?code=synthetic&state=%7B%22app_id%22%3A%20%22synthetic%22%7D",
        ]
        let advance = "window.webkit.messageHandlers.fixtureReady.postMessage('advance-sso');"
        let fixture = AppleWebKitFixture(script: stages.isEmpty ? finalScript : advance)
        var stage = 0
        fixture.onMessage = { [weak fixture] message in
            guard message == "advance-sso", stage < stages.count, let view = fixture?.webView else { return }
            let url = URL(string: stages[stage])!
            stage += 1
            let script = stage == stages.count ? finalScript : advance
            view.loadHTMLString("<!doctype html><html><body><script>\(script)</script></body></html>", baseURL: url)
        }
        return fixture
    }
}

@MainActor
private final class AppleWebKitFixture: NSObject, WKScriptMessageHandler {
    let script: String
    private let enablesPopupFixture: Bool
    var webView: WKWebView?
    var initialLoadCount = 0
    var completionCount = 0
    var callback: URL?
    var error: (any Error)?
    var lastMessage: String?
    var onMessage: (@MainActor (String?) -> Void)?

    init(script: String, enablesPopupFixture: Bool = false) {
        self.script = script
        self.enablesPopupFixture = enablesPopupFixture
    }

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
            // Only the popup-denial fixture enables generation of a real
            // new-window action. The production delegate must still deny it;
            // every other fixture retains the production preference.
            if self.enablesPopupFixture {
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            }
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
