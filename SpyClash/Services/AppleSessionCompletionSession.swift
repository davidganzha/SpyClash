import Foundation
import WebKit

/// Completes only the application's already-authorized Apple session. This
/// view is never attached to a window and cannot present provider sign-in UI.
/// The caller's WebAuthenticationCoordinator owns cancellation and the deadline.
@MainActor
final class AppleSessionCompletionSession: NSObject, WebAuthenticationSession {
    typealias WebViewFactory = @MainActor (WKWebViewConfiguration) -> WKWebView
    typealias RequestLoader = @MainActor (WKWebView, URLRequest) -> Void

    private let bootstrapURL: URL
    private var completion: WebAuthenticationCoordinator.Completion?
    private let makeWebView: WebViewFactory
    private let loadRequest: RequestLoader
    private var webView: WKWebView?
    private var started = false
    private var terminal = false
    private var navigationCount = 0
    private var documentGeneration = 0
    private var ssoProgress = SSOProgress.initial
    private var lastDiagnostic = AppleNativeHandoffDiagnostic(response: nil, destination: nil, redirectCount: 0)

    init(
        url: URL,
        completion: @escaping WebAuthenticationCoordinator.Completion,
        makeWebView: @escaping WebViewFactory = { WKWebView(frame: .zero, configuration: $0) },
        loadRequest: @escaping RequestLoader = { view, request in view.load(request) }
    ) {
        bootstrapURL = url
        self.completion = completion
        self.makeWebView = makeWebView
        self.loadRequest = loadRequest
    }

    func start() -> Bool {
        guard !started, !terminal else { return false }
        started = true
        do { try AppleNativeHandoffPolicy.validateBootstrap(bootstrapURL) }
        catch {
            finish(url: nil, error: error as? AppleNativeHandoffError ?? .invalidBootstrap)
            return false
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = makeWebView(configuration)
        view.isUserInteractionEnabled = false
        view.allowsBackForwardNavigationGestures = false
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view

        var request = URLRequest(url: bootstrapURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        loadRequest(view, request)
        return true
    }

    func cancel() {
        guard !terminal else { return }
        terminal = true
        completion = nil
        cleanUp()
    }

    private func cleanUp() {
        guard let view = webView else { return }
        webView = nil
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        view.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast,
            completionHandler: {}
        )
        // Destroying the sole owning view releases this attempt's isolated,
        // nonpersistent website data store. Nothing is shared with Safari.
    }

    private func finish(url: URL?, error: AppleNativeHandoffError?) {
        guard !terminal else { return }
        terminal = true
        let callback = completion
        completion = nil
        cleanUp()
        callback?(url, error)
    }

    private func owns(_ view: WKWebView) -> Bool {
        !terminal && webView === view
    }

    private func reject(_ error: AppleNativeHandoffError = .untrustedRedirect) {
        finish(url: nil, error: error.withDiagnostic(lastDiagnostic))
    }

    private func recordDiagnostic(response: URLResponse? = nil, destination: URL?) {
        // This stores only bounded enums/flags, never the URL or response.
        lastDiagnostic = AppleNativeHandoffDiagnostic(
            response: response, destination: destination, redirectCount: navigationCount
        )
    }

    /// Only the fixed native bootstrap and Base44 SSO routes may render. In
    /// particular, an expired ticket must never fall back to appleid.apple.com,
    /// a provider chooser, a login form, or the normal SpyClash website.
    static func permitsSessionDocument(_ url: URL) -> Bool {
        guard AppleNativeHandoffPolicy.permitsRedirect(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { return false }
        let appRoute = "/api/apps/69a0e57fa939f578082f8091/auth/sso/"
        if [appRoute + "login", appRoute + "callback"].contains(parts.percentEncodedPath) {
            return true
        }
        guard parts.percentEncodedHost == "spyclash.com",
              parts.percentEncodedPath == "/functions/appleAuthBroker" else { return false }
        let action = items.first(where: { $0.name == "action" })?.value
        if action == "native-bootstrap" {
            return (try? AppleNativeHandoffPolicy.validateBootstrap(url)) != nil
        }
        return action == "authorize"
    }

    private func completeIfCallback(_ url: URL) -> Bool {
        guard AppleNativeHandoffPolicy.isCallbackDestination(url) else { return false }
        do {
            _ = try AppleNativeHandoffPolicy.sessionAccessToken(from: url)
            finish(url: url, error: nil)
        } catch {
            reject(error as? AppleNativeHandoffError ?? .invalidCallback)
        }
        return true
    }

    private static func containsSessionCandidate(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains(where: { $0.name == "access_token" }) == true
    }

    /// Records only fixed stages, never the provider code, state or URL. A
    /// candidate may come only immediately after this attempt's SSO callback.
    /// It is still untrusted: native Apple binding must pass before any save.
    private enum SSOProgress {
        case initial, login, authorize, callback

        mutating func observePermittedDocument(_ url: URL) {
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let route = "/api/apps/69a0e57fa939f578082f8091/auth/sso/"
            let items = parts?.queryItems ?? []
            switch parts?.percentEncodedPath {
            case route + "login" where self == .initial || self == .login:
                self = .login
            case "/functions/appleAuthBroker" where self == .login || self == .authorize:
                self = items.first(where: { $0.name == "action" })?.value == "authorize" ? .authorize : .initial
            case route + "callback" where self == .authorize || self == .callback:
                let hasCodeAndState = ["code", "state"].allSatisfy { name in
                    guard let value = items.first(where: { $0.name == name })?.value else { return false }
                    return !value.isEmpty && value.utf8.count <= 20_000 &&
                        value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
                        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                }
                self = hasCodeAndState ? .callback : .initial
            default:
                self = .initial
            }
        }
    }
}

extension AppleSessionCompletionSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard owns(webView) else { return }
        documentGeneration += 1
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard owns(webView) else { decisionHandler(.cancel); return }
        // An auxiliary frame is not an authentication result. Block it without
        // letting it terminate the independently owned main-document attempt.
        if navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.cancel)
            return
        }
        if let url = navigationAction.request.url,
           (AppleNativeHandoffPolicy.isCallbackDestination(url) || Self.containsSessionCandidate(url)),
           !navigationAction.sourceFrame.isMainFrame {
            // A child cannot install credentials through _top or a new window,
            // or replace diagnostics belonging to the main document.
            decisionHandler(.cancel)
            return
        }
        recordDiagnostic(destination: navigationAction.request.url)
        guard navigationAction.targetFrame != nil else {
            decisionHandler(.cancel)
            reject(.validation(.navigationPopup))
            return
        }
        guard !navigationAction.shouldPerformDownload else {
            decisionHandler(.cancel)
            reject(.validation(.navigationDownload))
            return
        }
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            reject(.validation(.navigationURL))
            return
        }
        // Stop before a callback page, its SDK, or its credential-bearing URL
        // can load. The same policy applies to HTTP and JavaScript navigation.
        if AppleNativeHandoffPolicy.isCallbackDestination(url) {
            decisionHandler(.cancel)
            _ = completeIfCallback(url)
            return
        }
        if Self.containsSessionCandidate(url) {
            // Base44 may return its session through an intermediate landing
            // URL rather than directly to from_url. Never render that URL or
            // interpret its path/metadata as proof of authentication.
            decisionHandler(.cancel)
            guard navigationAction.request.httpMethod == "GET" else {
                reject(.validation(.navigationMethod)); return
            }
            guard ssoProgress == .callback else {
                reject(.validation(.navigationDocument)); return
            }
            do {
                let callback = try AppleNativeHandoffPolicy.unverifiedSessionCandidateCallback(from: url)
                finish(url: callback, error: nil)
            } catch {
                reject(error as? AppleNativeHandoffError ?? .invalidCallback)
            }
            return
        }
        navigationCount += 1
        recordDiagnostic(destination: url)
        guard navigationCount <= 16 else {
            decisionHandler(.cancel)
            reject(.redirectLimit)
            return
        }
        guard Self.permitsSessionDocument(url) else {
            decisionHandler(.cancel)
            reject(.validation(.navigationDocument))
            return
        }
        guard navigationAction.request.httpMethod == "GET" else {
            decisionHandler(.cancel)
            reject(.validation(.navigationMethod))
            return
        }
        if navigationAction.sourceFrame.isMainFrame {
            ssoProgress.observePermittedDocument(url)
        } else {
            ssoProgress = .initial
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard owns(webView) else { decisionHandler(.cancel); return }
        guard navigationResponse.isForMainFrame else { decisionHandler(.cancel); return }
        recordDiagnostic(response: navigationResponse.response, destination: navigationResponse.response.url)
        guard let url = navigationResponse.response.url else {
            decisionHandler(.cancel); reject(.validation(.navigationURL)); return
        }
        if AppleNativeHandoffPolicy.isCallbackDestination(url) {
            decisionHandler(.cancel); _ = completeIfCallback(url); return
        }
        guard Self.permitsSessionDocument(url) else {
            decisionHandler(.cancel); reject(.validation(.navigationDocument)); return
        }
        guard navigationResponse.canShowMIMEType else {
            decisionHandler(.cancel); reject(.validation(.navigationMIME)); return
        }
        if let response = navigationResponse.response as? HTTPURLResponse, !(200..<400).contains(response.statusCode) {
            decisionHandler(.cancel)
            reject(response.statusCode == 429 || response.statusCode >= 500 ? .temporarilyUnavailable : .providerRejected)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard owns(webView) else { return }
        let generation = documentGeneration
        // These completion documents may run redirects, but may not ask the
        // user to type credentials or interact with a hidden sign-in page.
        webView.evaluateJavaScript("Boolean(document.querySelector('form,input,textarea,select,button'))") { [weak self, weak webView] value, error in
            guard let self, let webView, self.owns(webView),
                  self.documentGeneration == generation else { return }
            if error != nil || value as? Bool == true { self.reject(.providerRejected) }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(webView, error: error)
    }

    private func navigationFailed(_ view: WKWebView, error: any Error) {
        guard owns(view) else { return }
        // Policy cancellations are handled before WebKit reports this error.
        if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled { return }
        reject(.temporarilyUnavailable)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard owns(webView) else { return }
        reject(.temporarilyUnavailable)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard owns(webView) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            reject(.providerRejected)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.cancel { _ in }
        if owns(webView), navigationAction.targetFrame?.isMainFrame != false {
            recordDiagnostic(destination: navigationAction.request.url)
            reject(.validation(.navigationDownload))
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.cancel { _ in }
        if owns(webView), navigationResponse.isForMainFrame {
            recordDiagnostic(response: navigationResponse.response, destination: navigationResponse.response.url)
            reject(.validation(.navigationDownload))
        }
    }
}

extension AppleSessionCompletionSession: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if owns(webView), navigationAction.sourceFrame.isMainFrame {
            recordDiagnostic(destination: navigationAction.request.url)
            reject(.validation(.navigationPopup))
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        completionHandler()
        if owns(webView) { reject(.providerRejected) }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        completionHandler(false)
        if owns(webView) { reject(.providerRejected) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler(nil)
        if owns(webView) { reject(.providerRejected) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
        if owns(webView) { reject(.providerRejected) }
    }

    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
        if owns(webView) { reject(.providerRejected) }
    }
}
