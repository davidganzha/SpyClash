import Foundation

enum AppleNativeHandoffError: Error, Equatable, LocalizedError, Sendable {
    case invalidBootstrap, invalidCallback, untrustedRedirect, redirectLimit, missingCallback
    case cancelled, expired, temporarilyUnavailable, providerRejected

    var errorDescription: String? {
        switch self {
        case .cancelled: "Apple sign-in was cancelled."
        case .expired: "Apple sign-in expired. Please try again."
        case .temporarilyUnavailable: "Apple sign-in is temporarily unavailable. Please try again."
        case .providerRejected: "Apple sign-in could not be completed. Please try again."
        default: "Apple sign-in returned an invalid response. Please try again."
        }
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
            throw AppleNativeHandoffError.invalidBootstrap
        }
        let items = parts.queryItems ?? []
        guard items.count == 2, Set(items.map(\.name)) == ["action", "ticket"],
              items.first(where: { $0.name == "action" })?.value == "native-bootstrap",
              let ticket = items.first(where: { $0.name == "ticket" })?.value,
              validValue(ticket, maximum: 20_000) else { throw AppleNativeHandoffError.invalidBootstrap }
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
            throw AppleNativeHandoffError.invalidCallback
        }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil else {
            throw AppleNativeHandoffError.invalidCallback
        }
        let isHTTPS = parts.scheme == "https" && parts.percentEncodedHost == "spyclash.com" &&
            parts.percentEncodedPath == callbackPath
        let isLegacy = parts.scheme == "spyclash" && parts.percentEncodedHost == "auth" &&
            ["", "/"].contains(parts.percentEncodedPath)
        guard isHTTPS || isLegacy else { throw AppleNativeHandoffError.invalidCallback }
        let items = parts.queryItems ?? []
        // URLComponents decodes names, so percent-encoded aliases also collide.
        guard Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ validValue($0.name, maximum: 128) && ($0.value.map { validValue($0, maximum: 20_000) } ?? false) }) else {
            throw AppleNativeHandoffError.invalidCallback
        }
        let provider = items.first { $0.name == "auth_provider" }
        guard provider?.value == "apple" || (isLegacy && provider == nil) else {
            throw AppleNativeHandoffError.invalidCallback
        }
        let tokenItem = items.first { $0.name == "access_token" }
        let errorItem = items.first { $0.name == "error" }
        let errorDescription = items.first { $0.name == "error_description" }
        guard (tokenItem != nil) != (errorItem != nil),
              tokenItem == nil || errorDescription == nil else { throw AppleNativeHandoffError.invalidCallback }
        if let error = errorItem?.value {
            switch error {
            case "access_denied", "user_cancelled", "user_canceled", "cancelled", "canceled": throw AppleNativeHandoffError.cancelled
            case "state_expired", "expired_state", "session_expired": throw AppleNativeHandoffError.expired
            case "temporarily_unavailable", "server_error", "service_unavailable": throw AppleNativeHandoffError.temporarilyUnavailable
            default: throw AppleNativeHandoffError.providerRejected
            }
        }
        guard let token = tokenItem?.value else { throw AppleNativeHandoffError.invalidCallback }
        return token
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
        let exceedsLimit = redirectCount > 12
        lock.unlock()
        guard !exceedsLimit else { record(.failure(.redirectLimit)); completionHandler(nil); return }
        if AppleNativeHandoffPolicy.isCallbackDestination(url) {
            do { record(.success(try AppleNativeHandoffPolicy.accessToken(from: url))) }
            catch { record(.failure(error as? AppleNativeHandoffError ?? .invalidCallback)) }
            completionHandler(nil)
        } else if AppleNativeHandoffPolicy.permitsRedirect(url) {
            completionHandler(request)
        } else {
            record(.failure(.untrustedRedirect))
            completionHandler(nil)
        }
    }

    func capturedResult() -> Result<String, AppleNativeHandoffError>? {
        lock.lock(); defer { lock.unlock() }; return result
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
        do {
            _ = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            // Some URLSession implementations report a stopped custom-scheme
            // redirect as a transport error after the delegate captured it.
            if let result = delegate.capturedResult() { return try result.get() }
            throw error
        }
        try Task.checkCancellation()
        guard let result = delegate.capturedResult() else { throw AppleNativeHandoffError.missingCallback }
        return try result.get()
    }
}
