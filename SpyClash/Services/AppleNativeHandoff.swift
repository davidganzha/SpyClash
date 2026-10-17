import Foundation

enum AppleNativeHandoffError: Error, Equatable, LocalizedError, Sendable {
    case invalidBootstrap, invalidCallback, untrustedRedirect, redirectLimit, missingCallback
    case cancelled, expired, temporarilyUnavailable, providerRejected
    case validation(AppleNativeHandoffFailureCode)
    case diagnosed(AppleNativeHandoffFailureCode, AppleNativeHandoffDiagnostic)

    var supportCode: AppleNativeHandoffFailureCode {
        switch self {
        case .invalidBootstrap: .invalidBootstrap
        case .invalidCallback: .invalidCallback
        case .untrustedRedirect: .untrustedRedirect
        case .redirectLimit: .redirectLimit
        case .missingCallback: .missingCallback
        case .cancelled: .cancelled
        case .expired: .expired
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .providerRejected: .providerRejected
        case .validation(let code), .diagnosed(let code, _): code
        }
    }

    func withDiagnostic(_ diagnostic: AppleNativeHandoffDiagnostic) -> Self {
        .diagnosed(supportCode, diagnostic)
    }

    /// The only value copied by the failure UI: fixed categories and bounded
    /// numbers, never a URL, credential or arbitrary server message.
    var diagnosticIdentifier: String {
        let suffix: String
        if case .diagnosed(_, let diagnostic) = self { suffix = diagnostic.supportSuffix }
        else { suffix = "" }
        return "SCA177-\(supportCode.rawValue)\(suffix)"
    }

    var errorDescription: String? {
        let message: String = switch supportCode {
        case .cancelled: "Apple sign-in was cancelled."
        case .expired: "Apple sign-in expired. Please try again."
        case .temporarilyUnavailable: "Apple sign-in is temporarily unavailable. Please try again."
        case .providerRejected: "Apple sign-in could not be completed. Please try again."
        default: "Apple sign-in returned an invalid response. Please try again."
        }
        return "[\(diagnosticIdentifier)]\n\(message)"
    }
}

/// Fixed classifications only. No server text, URL, query names or credentials
/// enter the diagnostic value, its description, or persistent storage.
enum AppleNativeHandoffFailureCode: String, Equatable, Sendable {
    case invalidBootstrap = "H01", invalidCallback = "H02", untrustedRedirect = "H03"
    case redirectLimit = "H04", missingCallback = "H05", cancelled = "H06"
    case expired = "H07", temporarilyUnavailable = "H08", providerRejected = "H09"
    case bootstrapOrigin = "H10", bootstrapQuery = "H11"
    case callbackFragment = "H20", callbackOrigin = "H21", callbackQuery = "H22"
    case callbackProvider = "H23", callbackPayload = "H24", callbackMissingToken = "H25"
    case callbackDuplicateQuery = "H26"
}

struct AppleNativeHandoffDiagnostic: Equatable, Sendable {
    enum Content: String, Sendable { case html = "H", json = "J", other = "O", absent = "N" }
    enum Endpoint: String, Sendable {
        case bootstrap = "NB", authorize = "AU", broker = "BR", ssoLogin = "SL", ssoCallback = "SC"
        case appleCallback = "AC", legacyCallback = "LC", otherTrusted = "OT", unknown = "UN"
    }
    enum Provider: String, Sendable { case apple = "A", google = "G", other = "O", absent = "N" }
    enum Fragment: String, Sendable { case absent = "N", inert = "I", other = "O" }

    let status: Int
    let content: Content
    let endpoint: Endpoint
    /// Bits: provider, token, error, description, unrelated parameter,
    /// duplicate name, nil/empty value, invalid value. Values are never retained.
    let queryFlags: UInt8
    let provider: Provider
    let fragment: Fragment
    let redirectCount: Int

    init(response: URLResponse?, destination: URL?, redirectCount: Int) {
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        status = (100...599).contains(httpStatus) ? httpStatus : 0
        switch response?.mimeType?.lowercased() {
        case "text/html", "application/xhtml+xml": content = .html
        case "application/json", "application/problem+json": content = .json
        case nil, "": content = .absent
        default: content = .other
        }
        self.redirectCount = min(max(redirectCount, 0), 13)
        let parts = destination.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let items = parts?.queryItems ?? []
        var flags: UInt8 = 0
        for item in items {
            let fieldFlag: UInt8 = switch item.name {
            case "auth_provider": 1
            case "access_token": 2
            case "error": 4
            case "error_description": 8
            default: 16
            }
            flags |= fieldFlag
            if item.value?.isEmpty != false { flags |= 64 }
            if let value = item.value,
               value.utf8.count > 20_000 || value != value.trimmingCharacters(in: .whitespacesAndNewlines) ||
                value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { flags |= 128 }
        }
        if Set(items.map(\.name)).count != items.count { flags |= 32 }
        queryFlags = flags
        switch items.first(where: { $0.name == "auth_provider" })?.value {
        case "apple": provider = .apple
        case "google": provider = .google
        case nil: provider = .absent
        default: provider = .other
        }
        if let raw = destination?.absoluteString, let hash = raw.firstIndex(of: "#") {
            fragment = ["#", "#_", "#_=_"].contains(String(raw[hash...])) ? .inert : .other
        } else { fragment = .absent }

        // Classification is deliberately narrower than URL display. Unknown
        // hosts/paths and attacker-controlled action strings remain fixed enums.
        if let parts, parts.user == nil, parts.password == nil, parts.port == nil,
           parts.scheme == "spyclash", parts.percentEncodedHost == "auth", ["", "/"].contains(parts.percentEncodedPath) {
            endpoint = .legacyCallback
        } else if let parts, parts.scheme == "https", parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.percentEncodedHost.map({ ["spyclash.com", "app.base44.com"].contains($0) }) == true {
            let path = parts.percentEncodedPath
            if parts.percentEncodedHost == "spyclash.com", path == AppleNativeHandoffPolicy.callbackPath {
                endpoint = .appleCallback
            } else if parts.percentEncodedHost == "spyclash.com", path == "/functions/appleAuthBroker" {
                switch items.first(where: { $0.name == "action" })?.value {
                case "native-bootstrap": endpoint = .bootstrap
                case "authorize": endpoint = .authorize
                default: endpoint = .broker
                }
            } else if path == "/api/apps/69a0e57fa939f578082f8091/auth/sso/login" { endpoint = .ssoLogin }
            else if path == "/api/apps/69a0e57fa939f578082f8091/auth/sso/callback" { endpoint = .ssoCallback }
            else { endpoint = .otherTrusted }
        } else { endpoint = .unknown }
    }

    var supportSuffix: String {
        "-r\(redirectCount)-s\(status)-c\(content.rawValue)-u\(endpoint.rawValue)-q\(String(queryFlags, radix: 16, uppercase: true))-p\(provider.rawValue)-f\(fragment.rawValue)"
    }
}

/// Apple owns this contract independently of the working Google browser flow.
enum AppleNativeHandoffPolicy {
    static let version = "apple-native-v2"
    static let callbackPath = "/MobileAppleAuthCallback.html"
    private static let allowedHosts: Set<String> = ["spyclash.com", "app.base44.com"]

    static func validateBootstrap(_ url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              isCanonicalHTTPS(parts), parts.percentEncodedHost == "spyclash.com",
              parts.percentEncodedPath == "/functions/appleAuthBroker", parts.fragment == nil else {
            throw AppleNativeHandoffError.validation(.bootstrapOrigin)
        }
        let items = parts.queryItems ?? []
        guard items.count == 2, Set(items.map(\.name)) == ["action", "ticket"],
              items.first(where: { $0.name == "action" })?.value == "native-bootstrap",
              let ticket = items.first(where: { $0.name == "ticket" })?.value,
              validValue(ticket, maximum: 20_000) else { throw AppleNativeHandoffError.validation(.bootstrapQuery) }
    }

    /// A matching destination is terminal even when its payload is malformed.
    /// Such responses must never fall through into website HTML or its SDK.
    static func isCallbackDestination(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "spyclash" ||
            (url.host?.lowercased() == "spyclash.com" && url.path == callbackPath)
    }

    static func permitsRedirect(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              isCanonicalHTTPS(parts), let host = parts.percentEncodedHost,
              allowedHosts.contains(host), parts.fragment == nil,
              !(parts.queryItems ?? []).contains(where: { ["access_token", "error", "error_description"].contains($0.name) }) else { return false }
        return true
    }

    static func accessToken(from url: URL) throws -> String {
        let raw = url.absoluteString
        if let hash = raw.firstIndex(of: "#"), !["#", "#_", "#_=_"].contains(String(raw[hash...])) {
            throw AppleNativeHandoffError.validation(.callbackFragment)
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil else {
            throw AppleNativeHandoffError.validation(.callbackOrigin)
        }
        let isHTTPS = parts.scheme == "https" && parts.percentEncodedHost == "spyclash.com" &&
            parts.percentEncodedPath == callbackPath
        let isLegacy = parts.scheme == "spyclash" && parts.percentEncodedHost == "auth" &&
            ["", "/"].contains(parts.percentEncodedPath)
        guard isHTTPS || isLegacy else { throw AppleNativeHandoffError.validation(.callbackOrigin) }
        let items = parts.queryItems ?? []
        // URLComponents decodes names, so percent-encoded aliases also collide.
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ validValue($0.name, maximum: 128) && ($0.value.map { validValue($0, maximum: 20_000) } ?? false) }) else {
            throw AppleNativeHandoffError.validation(Set(items.map(\.name)).count != items.count ? .callbackDuplicateQuery : .callbackQuery)
        }
        let provider = items.first { $0.name == "auth_provider" }
        guard provider?.value == "apple" || (isLegacy && provider == nil) else {
            throw AppleNativeHandoffError.validation(.callbackProvider)
        }
        let tokenItem = items.first { $0.name == "access_token" }
        let errorItem = items.first { $0.name == "error" }
        let errorDescription = items.first { $0.name == "error_description" }
        guard (tokenItem != nil) != (errorItem != nil),
              tokenItem == nil || errorDescription == nil else { throw AppleNativeHandoffError.validation(.callbackPayload) }
        if let error = errorItem?.value {
            switch error {
            case "access_denied", "user_cancelled", "user_canceled", "cancelled", "canceled": throw AppleNativeHandoffError.cancelled
            case "state_expired", "expired_state", "session_expired": throw AppleNativeHandoffError.expired
            case "temporarily_unavailable", "server_error", "service_unavailable": throw AppleNativeHandoffError.temporarilyUnavailable
            default: throw AppleNativeHandoffError.providerRejected
            }
        }
        guard let token = tokenItem?.value else { throw AppleNativeHandoffError.validation(.callbackMissingToken) }
        return token
    }

    /// The browser bridge is Apple-specific even though Google uses the same
    /// app scheme. Unlike the older direct transport, it never accepts an
    /// unmarked legacy callback or a webpage URL as its completion.
    static func browserAccessToken(from url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "spyclash" else {
            throw AppleNativeHandoffError.validation(.callbackOrigin)
        }
        guard parts.queryItems?.first(where: { $0.name == "auth_provider" })?.value == "apple" else {
            throw AppleNativeHandoffError.validation(.callbackProvider)
        }
        return try accessToken(from: url)
    }

    /// Internal completion accepts only explicitly Apple-marked callbacks.
    /// HTTPS is intercepted before loading the callback page; custom-scheme
    /// completion is supported for a script-driven return from trusted SSO.
    static func sessionAccessToken(from url: URL) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.first(where: { $0.name == "auth_provider" })?.value == "apple" else {
            throw AppleNativeHandoffError.validation(.callbackProvider)
        }
        return try accessToken(from: url)
    }

    private static func isCanonicalHTTPS(_ parts: URLComponents) -> Bool {
        parts.scheme == "https" && parts.user == nil && parts.password == nil && parts.port == nil
    }

    private static func validValue(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

final class AppleNativeHandoffRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, AppleNativeHandoffError>?
    private var redirectCount = 0

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url else { record(.failure(.untrustedRedirect)); completionHandler(nil); return }
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        lock.unlock()
        let diagnostic = AppleNativeHandoffDiagnostic(response: response, destination: url, redirectCount: count)
        guard count <= 12 else { record(.failure(AppleNativeHandoffError.redirectLimit.withDiagnostic(diagnostic))); completionHandler(nil); return }
        if AppleNativeHandoffPolicy.isCallbackDestination(url) {
            do { record(.success(try AppleNativeHandoffPolicy.accessToken(from: url))) }
            catch { record(.failure((error as? AppleNativeHandoffError ?? .invalidCallback).withDiagnostic(diagnostic))) }
            completionHandler(nil)
        } else if AppleNativeHandoffPolicy.permitsRedirect(url) {
            completionHandler(request)
        } else {
            record(.failure(AppleNativeHandoffError.untrustedRedirect.withDiagnostic(diagnostic)))
            completionHandler(nil)
        }
    }

    func capturedResult() -> Result<String, AppleNativeHandoffError>? {
        lock.lock(); defer { lock.unlock() }; return result
    }

    /// A completed HTTP response is not an authenticated callback. Classify its
    /// envelope only; HTML, JSON and response headers never supply credentials.
    func completedAccessToken(response: URLResponse?) throws -> String {
        try Task.checkCancellation()
        lock.lock()
        let captured = result
        let count = redirectCount
        lock.unlock()
        if let captured { return try captured.get() }
        throw AppleNativeHandoffError.missingCallback.withDiagnostic(
            AppleNativeHandoffDiagnostic(response: response, destination: response?.url, redirectCount: count)
        )
    }

    private func record(_ value: Result<String, AppleNativeHandoffError>) {
        lock.lock(); defer { lock.unlock() }
        if result == nil { result = value }
    }
}

enum AppleNativeHandoffTransport {
    static func accessToken(from bootstrapURL: URL) async throws -> String {
        try Task.checkCancellation()
        try AppleNativeHandoffPolicy.validateBootstrap(bootstrapURL)
        let delegate = AppleNativeHandoffRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: bootstrapURL)
        request.setValue("application/json,text/html", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let response: URLResponse
        do {
            // The body is deliberately ignored. A webpage/JSON response cannot
            // replace the exact authenticated HTTP redirect contract.
            (_, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            // Some URLSession implementations report a stopped custom-scheme
            // redirect as a transport error after the delegate captured it.
            if let result = delegate.capturedResult() { return try result.get() }
            throw error
        }
        return try delegate.completedAccessToken(response: response)
    }
}
