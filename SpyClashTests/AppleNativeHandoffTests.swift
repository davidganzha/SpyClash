import Foundation
import Network
import XCTest
@testable import SpyClash

@MainActor
final class AppleNativeHandoffTests: XCTestCase {
    private let base = "https://spyclash.com/MobileAppleAuthCallback.html"

    func testFreshAppleCredentialNegotiatesOnlyFixedVersion() throws {
        let credential = AppleSignInCredential(identityToken: "synthetic-identity", authorizationCode: "synthetic-code", rawNonce: "synthetic-nonce", state: "synthetic-state", appleUserID: "synthetic-user", email: nil, givenName: nil, familyName: nil)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(credential)) as? [String: String])
        XCTAssertEqual(body["handoff_version"], "apple-native-v2")
        XCTAssertNil(body["from_url"])
        XCTAssertNil(body["redirect_uri"])
    }

    func testAppleHTTPSAndLegacyCallbackAcceptOnlyInertRawMarkers() throws {
        for prefix in [base + "?auth_provider=apple&access_token=synthetic", "spyclash://auth?access_token=synthetic", "spyclash://auth/?auth_provider=apple&access_token=synthetic"] {
            for suffix in ["", "#", "#_", "#_=_"] {
                XCTAssertEqual(try AppleNativeHandoffPolicy.accessToken(from: XCTUnwrap(URL(string: prefix + suffix))), "synthetic")
            }
        }
    }

    func testAppleCallbackRejectsAmbiguousPayloadAndEncodedAliases() throws {
        let invalid = [
            "?access_token=synthetic", "?auth_provider=google&access_token=synthetic",
            "?auth_provider=apple&auth_provider=apple&access_token=synthetic",
            "?auth_provider=apple&%61uth_provider=apple&access_token=synthetic",
            "?auth_provider=apple&access_token=synthetic&access%5Ftoken=second",
            "?auth_provider=apple&access_token=synthetic&error=access_denied",
            "?auth_provider=apple&access_token=synthetic&error_description=ignored",
            "?auth_provider=apple&error_description=ignored", "?auth_provider=apple&access_token=",
            "?auth_provider=apple&access_token=%00", "?auth_provider=apple&access_token=%20synthetic",
            "?auth_provider=apple&access_token=synthetic%0A", "?auth_provider=apple&access_token=synthetic&x=%7F",
            "?auth_provider=apple&access_token=synthetic#access_token=other",
            "?auth_provider=apple&access_token=synthetic#%5F", "?auth_provider=apple&access_token=synthetic#_=_%20",
            "?auth_provider=apple&access_token=synthetic#_=_#", "?auth_provider=apple&access_token=" + String(repeating: "x", count: 20_001),
        ]
        for query in invalid {
            XCTAssertThrowsError(try AppleNativeHandoffPolicy.accessToken(from: XCTUnwrap(URL(string: base + query))))
        }
        // Provider errors are fixed local classifications, never reflected arbitrary text.
        XCTAssertThrowsError(try AppleNativeHandoffPolicy.accessToken(from: XCTUnwrap(URL(string: base + "?auth_provider=apple&error=attacker-text")))) {
            XCTAssertEqual($0 as? AppleNativeHandoffError, .providerRejected)
            XCTAssertFalse($0.localizedDescription.contains("attacker-text"))
        }
    }

    func testAppleCallbackRejectsOriginPathPortAndUserinfoConfusion() throws {
        for prefix in [
            "http://spyclash.com/MobileAppleAuthCallback.html", "https://spyclash.com:443/MobileAppleAuthCallback.html",
            "https://user@spyclash.com/MobileAppleAuthCallback.html", "https://spyclash.com.attacker.example/MobileAppleAuthCallback.html",
            "https://spyclash.com/MobileAuthCallback.html", "https://spyclash.com/MobileAppleAuthCallback.html/extra",
            "https://spyclash.com/%4DobileAppleAuthCallback.html", "spyclash://auth:443", "spyclash://user@auth", "spyclash://auth/extra",
        ] {
            let url = try XCTUnwrap(URL(string: prefix + "?auth_provider=apple&access_token=synthetic"))
            XCTAssertThrowsError(try AppleNativeHandoffPolicy.accessToken(from: url))
            XCTAssertFalse(AppleNativeHandoffPolicy.permitsRedirect(url), "A rejected token-bearing callback must not be fetched")
        }
    }

    func testBootstrapAndIntermediateRedirectPolicyStayCanonical() throws {
        let bootstrap = "https://spyclash.com/functions/appleAuthBroker?action=native-bootstrap&ticket=synthetic"
        XCTAssertNoThrow(try AppleNativeHandoffPolicy.validateBootstrap(XCTUnwrap(URL(string: bootstrap))))
        for invalid in [bootstrap + "&ticket=second", bootstrap + "#", bootstrap.replacingOccurrences(of: "https:", with: "http:"), bootstrap.replacingOccurrences(of: "spyclash.com/", with: "spyclash.com:443/"), bootstrap.replacingOccurrences(of: "functions/", with: "other/"), bootstrap.replacingOccurrences(of: "native-bootstrap", with: "authorize")] {
            XCTAssertThrowsError(try AppleNativeHandoffPolicy.validateBootstrap(XCTUnwrap(URL(string: invalid))))
        }
        for value in ["https://spyclash.com/functions/appleAuthBroker?action=authorize&state=synthetic", "https://app.base44.com/api/apps/69a0e57fa939f578082f8091/auth/sso/callback?code=synthetic"] {
            XCTAssertTrue(AppleNativeHandoffPolicy.permitsRedirect(try XCTUnwrap(URL(string: value))))
        }
        for value in ["https://appleid.apple.com/auth/authorize", "http://spyclash.com/", "https://spyclash.com:443/", "https://user@spyclash.com/", "https://app.base44.com.evil.example/", "https://spyclash.com/#access_token=synthetic"] {
            XCTAssertFalse(AppleNativeHandoffPolicy.permitsRedirect(try XCTUnwrap(URL(string: value))))
        }
    }

    func testRealURLSessionInterceptsCanonicalHTTPSBeforeRequestingHTML() async throws {
        let destination = base + "?auth_provider=apple&access_token=synthetic-loopback#_=_"
        let server = try AppleHandoffLoopbackServer(location: destination)
        let url = try await server.start()
        defer { server.stop() }
        let delegate = AppleNativeHandoffRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 302)
        XCTAssertEqual(try XCTUnwrap(delegate.capturedResult()).get(), "synthetic-loopback")
        XCTAssertEqual(server.requestCount, 1)
    }

    func testRealURLSessionRejectsCredentialFragmentAndPreservesLegacyReturn() async throws {
        for (destination, expected) in [
            (base + "?auth_provider=apple&access_token=synthetic#access_token=bad", Result<String, AppleNativeHandoffError>.failure(.invalidCallback)),
            ("spyclash://auth?access_token=synthetic-legacy", .success("synthetic-legacy")),
            (base + "?auth_provider=apple&error=access_denied", .failure(.cancelled)),
        ] {
            let server = try AppleHandoffLoopbackServer(location: destination)
            let url = try await server.start()
            defer { server.stop() }
            let delegate = AppleNativeHandoffRedirectDelegate()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            // URLSession may report unsupportedURL for a custom scheme after
            // its redirect delegate has already captured the terminal result.
            _ = try? await session.data(from: url)
            switch expected {
            case .success(let token): XCTAssertEqual(try XCTUnwrap(delegate.capturedResult()).get(), token)
            case .failure(let error):
                guard case .failure(let actual)? = delegate.capturedResult() else { XCTFail("Expected rejected callback"); continue }
                XCTAssertEqual(actual, error)
            }
            XCTAssertEqual(server.requestCount, 1)
        }
    }
}

/// Real HTTP only on loopback; the redirect target is always inspected and
/// stopped by the production delegate. No provider credentials or website calls.
private final class AppleHandoffLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SpyClash.AppleHandoffTests.loopback")
    private let location: String
    private var count = 0
    private var startupCompleted = false
    var requestCount: Int { queue.sync { count } }

    init(location: String) throws {
        self.location = location
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startupCompleted else { return }
                switch state {
                case .ready:
                    self.startupCompleted = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/bootstrap")!)
                case .failed(let error): self.startupCompleted = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.count += 1
                let response = "HTTP/1.1 302 Found\r\nLocation: \(self.location)\r\nContent-Length: 0\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if error != nil || complete || bytes.count > 8192 {
                connection.cancel()
            } else { self.receive(connection, accumulated: bytes) }
        }
    }

    func stop() { listener.cancel() }
}
