import Foundation
import XCTest
@testable import SpyClashSupabaseTest

@MainActor
final class Base44IsolationTests: XCTestCase {
    func testProductionAuthPushAndGameRoutesNeverReachBase44Transport() async throws {
        XCTAssertTrue(SupabaseTestEnvironment.isEnabled)
        XCTAssertEqual(SupabaseTestEnvironment.configurationURL.path, "/dev/null", "Unit tests must not restore a saved Simulator lab account")
        let observer = IsolationRequestObserver.shared
        observer.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IsolationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = Base44Client(session: session)
        client.setToken("synthetic-token-never-sent")

        await expectBlocked {
            _ = try await client.login(email: "blocked@example.test", password: "synthetic-never-sent")
        }
        XCTAssertEqual(observer.count, 0, "Generic production REST must be blocked before URLSession")

        await expectBlocked {
            try await client.unregisterPushDevice(installationID: "synthetic-installation")
        }
        XCTAssertEqual(observer.count, 0, "The separate push transport must also be blocked")

        await expectBlocked {
            _ = try await client.appleNativeAccessToken(for: AppleSignInCredential(
                identityToken: "synthetic-identity", authorizationCode: "synthetic-code",
                rawNonce: "synthetic-nonce", state: "synthetic-state", appleUserID: "synthetic-user",
                email: nil, givenName: nil, familyName: nil
            ), handoff: { _ in
                XCTFail("Test backend must reject Apple auth before starting a production handoff")
                throw URLError(.unsupportedURL)
            })
        }
        XCTAssertEqual(observer.count, 0, "Native Apple bootstrap must not escape the test backend")

        let room = try JSONDecoder().decode(GameRoom.self, from: Data(
            #"{"id":"20000000-0000-0000-0000-000000000001","code":"test","status":"playing"}"#.utf8
        ))
        do {
            _ = try await client.pauseGame(room: room)
            XCTFail("An unsigned full-game action must fail before either transport")
        } catch let error as Base44Error {
            XCTAssertEqual(error.code, "not_signed_in")
        }
        XCTAssertEqual(observer.count, 0)
    }

    private func expectBlocked(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected test-build production transport rejection", file: file, line: line)
        } catch let error as Base44Error {
            XCTAssertEqual(error.statusCode, 403, file: file, line: line)
            XCTAssertEqual(error.code, "base44_disabled_in_supabase_test", file: file, line: line)
        } catch {
            XCTFail("Expected the explicit isolation error, received \(type(of: error))", file: file, line: line)
        }
    }
}

private final class IsolationRequestObserver: @unchecked Sendable {
    static let shared = IsolationRequestObserver()
    private let lock = NSLock()
    private var observed = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return observed
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        observed = 0
    }

    func record() {
        lock.lock(); defer { lock.unlock() }
        observed += 1
    }
}

/// Observe every URLSession attempt without making any real network request.
private final class IsolationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        IsolationRequestObserver.shared.record()
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}
