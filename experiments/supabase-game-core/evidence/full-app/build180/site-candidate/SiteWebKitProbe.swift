import AppKit
import WebKit
import CryptoKit

struct ProbeCase {
    let name: String
    let path: String
    let suffix: String
    let expected: String?
    init(_ name: String, _ suffix: String, _ expected: String?, path: String = "/MobileAppleAuthCallback.html") {
        self.name = name; self.path = path; self.suffix = suffix; self.expected = expected
    }
}

@MainActor final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    private var web: WKWebView!
    private var index = 0
    private var reports = [[String: Any]]()
    private var navigationTargets = [String]()
    private var loadingSyntheticDocument = false
    private let outputURL: URL
    private let source: String
    private let guards: String
    private let sourceHash: String
    private let guardsHash: String
    private let cases: [ProbeCase] = [
        .init("apple_query", "?auth_provider=apple&access_token=fixture180", "spyclash://auth?auth_provider=apple&access_token=fixture180"),
        .init("apple_inert_fragment", "?auth_provider=apple&access_token=fixture180#_=_", "spyclash://auth?auth_provider=apple&access_token=fixture180"),
        .init("apple_literal_plus", "?auth_provider=apple&access_token=fixture+180", "spyclash://auth?auth_provider=apple&access_token=fixture%2B180"),
        .init("apple_safe_error", "?auth_provider=apple&error=access_denied&error_description=fixture180", "spyclash://auth?auth_provider=apple&error=access_denied"),
        .init("apple_unknown_error", "?auth_provider=apple&error=fixture180", "spyclash://auth?auth_provider=apple&error=authentication_failed"),
        .init("apple_wrong_provider", "?auth_provider=google&access_token=fixture180", nil),
        .init("apple_missing_provider", "?access_token=fixture180", nil),
        .init("apple_duplicate", "?auth_provider=apple&access_token=fixture180&access%5Ftoken=other180", nil),
        .init("apple_mixed_payload", "?auth_provider=apple&access_token=fixture180&error=access_denied", nil),
        .init("apple_credential_fragment", "?auth_provider=apple&access_token=fixture180#access_token=other180", nil),
        .init("apple_cleaned_reload", "", nil),
        .init("google_query_preserved", "?auth_provider=google&access_token=fixture180", "spyclash://auth?access_token=fixture180", path: "/MobileAuthCallback.html"),
        .init("google_inert_fragment_preserved", "?auth_provider=google&access_token=fixture180#_=_", "spyclash://auth?access_token=fixture180", path: "/MobileAuthCallback.html")
    ]
    init(root: URL) throws {
        outputURL = root.appendingPathComponent("site-webkit-probe/outcome.json")
        let sourceData = try Data(contentsOf: root.appendingPathComponent("site-deploy/dist/assets/index-B5iDK17o.js"))
        let guardsData = try Data(contentsOf: root.appendingPathComponent("site-webkit-probe/inline-guards.js"))
        source = String(decoding: sourceData, as: UTF8.self)
        guards = String(decoding: guardsData, as: UTF8.self)
        sourceHash = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        guardsHash = SHA256.hash(data: guardsData).map { String(format: "%02x", $0) }.joined()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.finish(timeout: true) }
        next()
    }
    private func next() {
        guard index < cases.count else { finish(timeout: false); return }
        navigationTargets = []
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let rules = "[{\"trigger\":{\"url-filter\":\".*\"},\"action\":{\"type\":\"block\"}}]"
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "SpyClash180NoNetwork", encodedContentRuleList: rules) { [weak self] rule, error in
            guard let self else { return }
            guard let rule, error == nil else { self.finish(timeout: true); return }
            config.userContentController.add(rule)
            self.web = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 900), configuration: config)
            self.web.navigationDelegate = self
            let test = self.cases[self.index]
            let url = URL(string: "https://spyclash.com" + test.path + test.suffix)!
            self.loadingSyntheticDocument = true
            self.web.loadHTMLString("<!doctype html><html><head><meta name='referrer' content='no-referrer'></head><body><div id='root'></div></body></html>", baseURL: url)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if loadingSyntheticDocument { loadingSyntheticDocument = false; decisionHandler(.allow) }
        else { navigationTargets.append(action.request.url?.absoluteString ?? ""); decisionHandler(.cancel) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = """
        (() => {
          window.__probe = {storage:0, fetch:0, xhr:0, workers:0, caches:0, errors:0};
          window.addEventListener('error', () => window.__probe.errors++);
          window.addEventListener('unhandledrejection', () => window.__probe.errors++);
          for (const name of ['localStorage','sessionStorage']) Object.defineProperty(window,name,{get(){window.__probe.storage++;throw new Error('storage blocked')}});
          window.fetch = () => {window.__probe.fetch++;return Promise.reject(new Error('network blocked'))};
          window.XMLHttpRequest = function(){window.__probe.xhr++;throw new Error('network blocked')};
          Object.defineProperty(navigator,'serviceWorker',{get(){window.__probe.workers++;throw new Error('worker blocked')}});
          Object.defineProperty(window,'caches',{get(){window.__probe.caches++;throw new Error('cache blocked')}});
          \(guards)
          \(source)
          return true;
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, executionError in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.collect(webView, executionError: executionError != nil)
            }
        }
    }
    private func collect(_ webView: WKWebView, executionError: Bool) {
        webView.evaluateJavaScript("""
        (() => {
          const link = document.getElementById('open-app');
          return {accepted:!!link && !link.hidden && link.hasAttribute('href'), href:link?.href ?? '',
            queryCleaned:location.search === '', fragmentCleaned:!location.href.includes('#'),
            noCredentialInText:!document.body.textContent.includes('fixture180') && !document.body.textContent.includes('other180'),
            noBootstrapPreload:document.querySelectorAll('link[rel="modulepreload"],link[rel="stylesheet"]').length===0,
            counts:window.__probe, diagnostic:document.getElementById('diagnostic')?.textContent ?? ''};
        })();
        """) { [weak self] value, error in
            guard let self else { return }
            let test = self.cases[self.index]
            var row = (value as? [String: Any]) ?? [:]
            let href = row.removeValue(forKey: "href") as? String ?? ""
            let counts = row["counts"] as? [String: Int] ?? [:]
            let expectedAccepted = test.expected != nil
            let expectedURL = test.expected.flatMap(URL.init(string:))
            // URL query ordering does not affect the callback contract.
            func sameDestination(_ raw: String) -> Bool {
                guard let actual = URLComponents(string: raw), let expectedURL,
                      let expected = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false) else { return false }
                return actual.scheme == expected.scheme && actual.host == expected.host && actual.path == expected.path && actual.fragment == nil &&
                    Set(actual.queryItems ?? []) == Set(expected.queryItems ?? [])
            }
            row["case"] = test.name
            row["expectedAccepted"] = expectedAccepted
            row["engineError"] = error != nil || executionError
            row["fixedDestinationAndPayload"] = expectedAccepted ? sameDestination(href) : href.isEmpty
            row["nativeNavigationCount"] = self.navigationTargets.count
            row["nativeNavigationIntercepted"] = expectedAccepted ? self.navigationTargets.count == 1 && self.navigationTargets.allSatisfy(sameDestination) : self.navigationTargets.isEmpty
            row["noStorageSDKOrNetworkCalls"] = counts.count == 6 && counts.values.allSatisfy { $0 == 0 }
            row["passed"] = error == nil && !executionError && row["accepted"] as? Bool == expectedAccepted &&
                ["queryCleaned", "fragmentCleaned", "fixedDestinationAndPayload", "noCredentialInText", "noBootstrapPreload", "nativeNavigationIntercepted", "noStorageSDKOrNetworkCalls"].allSatisfy { row[$0] as? Bool == true }
            self.reports.append(row)
            self.index += 1
            self.next()
        }
    }
    private func finish(timeout: Bool) {
        let payload: [String: Any] = ["engine": "macOS WKWebView", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "builtEntrySHA256": sourceHash, "actualBuiltInlineGuardsSHA256": guardsHash,
            "syntheticOnly": true, "allNetworkBlockedByContentRule": true, "nativeNavigationInterceptedAndCancelled": true,
            "execution": "Actual unmodified frozen Vite entry and actual built HTML inline guards in synthetic HTTPS documents; no Apple auth/session", "timeout": timeout,
            "caseCount": reports.count, "passed": !timeout && reports.count == cases.count && reports.allSatisfy { $0["passed"] as? Bool == true }, "cases": reports]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: outputURL, options: .atomic) }
        NSApp.terminate(nil)
    }
}

@main struct Runner {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPYCLASH_SITE_PROBE_ROOT"]!)
        let app = NSApplication.shared
        let delegate = try Probe(root: root)
        app.delegate = delegate
        app.run()
    }
}
