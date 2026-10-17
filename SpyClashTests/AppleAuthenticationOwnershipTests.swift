import AuthenticationServices
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import SpyClash

@MainActor
final class AppleAuthenticationOwnershipTests: XCTestCase {
    private let bootstrapURL = URL(string: "https://spyclash.com/functions/appleAuthBroker?action=native-bootstrap&ticket=synthetic-ticket")!

    private func makeState() -> AppState {
        AppState(
            client: Base44Client(),
            readStoredToken: { nil },
            saveStoredToken: { _ in XCTFail("Apple cancellation must not save a token") },
            clearStoredToken: { XCTFail("Apple cancellation must not clear a token") }
        )
    }

    func testLateCancelledAppleRequestCannotConsumeReplacementAuthorization() async {
        let state = makeState()
        let oldID = UUID()
        let oldRequest = ASAuthorizationAppleIDProvider().createRequest()
        state.configureAppleSignInRequest(oldRequest, requestID: oldID)
        XCTAssertNotNil(oldRequest.state)
        XCTAssertTrue(state.isAppleAuthorizationPending)
        state.cancelAppleSignInRequest()

        let newID = UUID()
        let newRequest = ASAuthorizationAppleIDProvider().createRequest()
        state.configureAppleSignInRequest(newRequest, requestID: newID)
        XCTAssertNotNil(newRequest.state)
        XCTAssertNotEqual(oldRequest.state, newRequest.state)
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.isAppleAuthorizationPending)

        await state.completeAppleSignIn(.failure(ASAuthorizationError(.canceled)), requestID: oldID)

        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.isAppleAuthorizationPending)
        XCTAssertNil(state.authError)
        XCTAssertNil(state.appleAuthStage)
        state.cancelAppleSignInRequest()
    }

    func testCurrentAppleCancellationClearsOwnershipAndAllowsNextRequest() async {
        let state = makeState()
        let requestID = UUID()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        state.configureAppleSignInRequest(request, requestID: requestID)
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.isAppleAuthorizationPending)

        await state.completeAppleSignIn(.failure(ASAuthorizationError(.canceled)), requestID: requestID)

        XCTAssertFalse(state.isBusy)
        XCTAssertFalse(state.isAppleAuthorizationPending)
        XCTAssertNil(state.authError)
        XCTAssertNil(state.appleAuthStage)

        let nextRequest = ASAuthorizationAppleIDProvider().createRequest()
        state.configureAppleSignInRequest(nextRequest, requestID: UUID())
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.isAppleAuthorizationPending)
        XCTAssertNotNil(nextRequest.state)
        state.cancelAppleSignInRequest()
    }

    func testNativeExchangeUsesOwnedBrowserOnceAndPreservesBindingTicket() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppleBootstrapURLProtocol.self]
        let client = Base44Client(session: URLSession(configuration: configuration))
        client.setToken("existing-session")
        let exchange = expectation(description: "Only the native credential exchange uses URLSession")
        exchange.assertForOverFulfill = true
        AppleBootstrapURLProtocol.handler = { request in
            XCTAssertEqual(request.request.httpMethod, "POST")
            XCTAssertEqual(request.request.url?.path, "/functions/appleAuthBroker")
            XCTAssertEqual(URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "action", value: "native-exchange")])
            exchange.fulfill()
            request.respond(body: #"{"bootstrap_url":"https://spyclash.com/functions/appleAuthBroker?action=native-bootstrap&ticket=synthetic-ticket","binding_ticket":"synthetic-binding","expires_in":90}"#)
        }
        defer { AppleBootstrapURLProtocol.handler = nil }
        var browserStarts = 0
        let coordinator = WebAuthenticationCoordinator(makeSession: { url, completion in
            browserStarts += 1
            XCTAssertEqual(url, self.bootstrapURL)
            let session = AppleHandoffTestSession(completion: completion)
            session.onStart = {
                completion(URL(string: "spyclash://auth?auth_provider=apple&access_token=synthetic-session"), nil)
            }
            return session
        })
        let state = AppState(client: client, readStoredToken: { nil },
                             saveStoredToken: { _ in XCTFail("A handoff must not commit a session before profile verification") },
                             clearStoredToken: { XCTFail("A handoff must preserve the existing session") },
                             webAuthentication: coordinator)
        let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
        let credential = AppleSignInCredential(identityToken: "synthetic-identity", authorizationCode: "synthetic-code",
                                               rawNonce: "synthetic-nonce", state: "synthetic-state", appleUserID: "synthetic-user",
                                               email: nil, givenName: nil, familyName: nil)
        var phases: [String] = []
        let result = try await client.appleNativeAccessToken(for: credential, onPhaseChange: { phase in
            switch phase {
            case .verifyingIdentity: phases.append("verify")
            case .establishingSession: phases.append("session")
            }
        }, handoff: { url in
            try await state.completeAppleBrowserHandoff(from: url, attemptID: attempt)
        })
        await fulfillment(of: [exchange], timeout: 1)
        XCTAssertEqual(browserStarts, 1)
        XCTAssertEqual(phases, ["verify", "session"])
        XCTAssertEqual(result.accessToken, "synthetic-session")
        XCTAssertEqual(result.bindingTicket, "synthetic-binding")
        XCTAssertEqual(client.currentAccessToken, "existing-session")
        XCTAssertNil(state.user)
    }

    func testAppleBrowserRejectsUntrustedBootstrapBeforeOpeningSession() async throws {
        let coordinator = WebAuthenticationCoordinator(makeSession: { _, completion in
            XCTFail("Untrusted bootstrap must not reach a browser")
            return AppleHandoffTestSession(completion: completion)
        })
        let state = AppState(client: Base44Client(), readStoredToken: { nil }, webAuthentication: coordinator)
        let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
        do {
            _ = try await state.completeAppleBrowserHandoff(from: URL(string: "https://foreign.example/?ticket=synthetic")!, attemptID: attempt)
            XCTFail("Untrusted bootstrap was accepted")
        } catch {
            XCTAssertEqual(error as? AppleNativeHandoffError, .validation(.bootstrapOrigin))
        }
    }

    func testLogoutCancelsAppleBrowserAndRejectsItsLateCompletion() async throws {
        var session: AppleHandoffTestSession?
        let coordinator = WebAuthenticationCoordinator(makeSession: { _, completion in
            let created = AppleHandoffTestSession(completion: completion)
            session = created
            return created
        })
        let client = Base44Client()
        var savedTokens: [String] = []
        let state = AppState(client: client, readStoredToken: { nil }, saveStoredToken: { savedTokens.append($0) },
                             clearStoredToken: {}, webAuthentication: coordinator)
        let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
        let task = Task { try await state.completeAppleBrowserHandoff(from: bootstrapURL, attemptID: attempt) }
        let opened = try await waitForBrowser { session }
        state.logout()
        client.setToken("replacement-session")
        opened.completion(URL(string: "spyclash://auth?auth_provider=apple&access_token=late-session"), nil)
        do { _ = try await task.value; XCTFail("Cancelled browser returned a credential") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(opened.cancelCount, 1)
        XCTAssertEqual(client.currentAccessToken, "replacement-session")
        XCTAssertTrue(savedTokens.isEmpty)
        XCTAssertNil(state.authError)
        XCTAssertNil(state.appleHandoffFailure)
    }

    func testAppleBrowserRejectsSuccessAndFailureAfterAccountGenerationChanges() async throws {
        for failed in [false, true] {
            var session: AppleHandoffTestSession?
            let coordinator = WebAuthenticationCoordinator(makeSession: { _, completion in
                let created = AppleHandoffTestSession(completion: completion)
                session = created
                return created
            })
            let client = Base44Client()
            let state = AppState(client: client, readStoredToken: { nil }, webAuthentication: coordinator)
            let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
            let task = Task { try await state.completeAppleBrowserHandoff(from: bootstrapURL, attemptID: attempt) }
            let opened = try await waitForBrowser { session }
            client.setToken("replacement-session")
            if failed { opened.completion(nil, NSError(domain: "synthetic-browser-error", code: 1)) }
            else { opened.completion(URL(string: "spyclash://auth?auth_provider=apple&access_token=late-session"), nil) }
            do { _ = try await task.value; XCTFail("A stale account generation produced a credential or visible failure") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(client.currentAccessToken, "replacement-session")
            XCTAssertNil(state.authError)
            XCTAssertNil(state.appleHandoffFailure)
        }
    }

    func testAppleBrowserCancellationIsSilentAndWrongProviderHasSafeDiagnostic() async throws {
        for outcome in ["browser-cancelled", "provider-cancelled", "wrong-provider"] {
            let coordinator = WebAuthenticationCoordinator(makeSession: { _, completion in
                let session = AppleHandoffTestSession(completion: completion)
                session.onStart = {
                    if outcome == "browser-cancelled" { completion(nil, ASWebAuthenticationSessionError(.canceledLogin)) }
                    else if outcome == "provider-cancelled" { completion(URL(string: "spyclash://auth?auth_provider=apple&error=access_denied"), nil) }
                    else { completion(URL(string: "spyclash://auth?auth_provider=google&access_token=must-not-appear"), nil) }
                }
                return session
            })
            let state = AppState(client: Base44Client(), readStoredToken: { nil }, webAuthentication: coordinator)
            let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
            do { _ = try await state.completeAppleBrowserHandoff(from: bootstrapURL, attemptID: attempt); XCTFail("Invalid completion was accepted") }
            catch {
                if outcome != "wrong-provider" { XCTAssertTrue(error is CancellationError) }
                else {
                    XCTAssertEqual((error as? AppleNativeHandoffError)?.supportCode, .callbackProvider)
                    XCTAssertFalse(error.localizedDescription.contains("must-not-appear"))
                }
            }
        }
    }

    func testAppleBrowserCannotCompleteAfterNativeTicketDeadline() async throws {
        var now = Date(timeIntervalSince1970: 1_000)
        var session: AppleHandoffTestSession?
        let coordinator = WebAuthenticationCoordinator(makeSession: { _, completion in
            let created = AppleHandoffTestSession(completion: completion)
            session = created
            return created
        }, now: { now })
        let state = AppState(client: Base44Client(), readStoredToken: { nil }, webAuthentication: coordinator)
        let attempt = try XCTUnwrap(state.beginAuthenticationAttempt())
        let task = Task { try await state.completeAppleBrowserHandoff(from: bootstrapURL, attemptID: attempt) }
        let opened = try await waitForBrowser { session }
        now = now.addingTimeInterval(91)
        opened.completion(URL(string: "spyclash://auth?auth_provider=apple&access_token=expired-session"), nil)
        do { _ = try await task.value; XCTFail("Browser accepted a callback beyond the native ticket deadline") }
        catch { XCTAssertEqual(error as? AppleNativeHandoffError, .expired) }
        XCTAssertEqual(opened.cancelCount, 1)
    }

    private func waitForBrowser(_ value: () -> AppleHandoffTestSession?) async throws -> AppleHandoffTestSession {
        for _ in 0..<100 {
            if let session = value() { return session }
            try await Task.sleep(for: .milliseconds(5))
        }
        return try XCTUnwrap(value(), "Owned browser was not started within the bounded wait")
    }

    func testAppleHandoffFailureSurvivesToastDismissalAndClearsBeforeRetry() async throws {
        let state = makeState()
        let failure = AppleNativeHandoffError.missingCallback.withDiagnostic(
            AppleNativeHandoffDiagnostic(response: nil, destination: nil, redirectCount: 4)
        )
        let requestID = UUID()
        state.configureAppleSignInRequest(ASAuthorizationAppleIDProvider().createRequest(), requestID: requestID)
        await state.completeAppleSignIn(.failure(failure), requestID: requestID)

        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.appleHandoffFailure, failure)
        for notice in state.toastNotices { state.dismissToast(notice.id) }
        XCTAssertTrue(state.toastNotices.isEmpty)
        XCTAssertEqual(try XCTUnwrap(state.appleHandoffFailure).diagnosticIdentifier, "SCA177-H05-r4-s0-cN-uUN-q0-pN-fN")

        let retryID = UUID()
        state.configureAppleSignInRequest(ASAuthorizationAppleIDProvider().createRequest(), requestID: retryID)
        XCTAssertNil(state.appleHandoffFailure)
        XCTAssertNil(state.authError)
        // A late failure from the previous request cannot reopen its alert.
        await state.completeAppleSignIn(.failure(failure), requestID: requestID)
        XCTAssertNil(state.appleHandoffFailure)
        XCTAssertTrue(state.isAppleAuthorizationPending)
        await state.completeAppleSignIn(.failure(ASAuthorizationError(.canceled)), requestID: retryID)
        XCTAssertNil(state.appleHandoffFailure)
    }

    func testOnlyTypedAppleFailureCanPresentSupportAlertAndDismissalPreservesError() async {
        let state = makeState()
        let requestID = UUID()
        state.configureAppleSignInRequest(ASAuthorizationAppleIDProvider().createRequest(), requestID: requestID)
        await state.completeAppleSignIn(.failure(AppleNativeHandoffError.invalidCallback), requestID: requestID)
        XCTAssertNotNil(state.appleHandoffFailure)
        let originalMessage = state.authError
        state.dismissAppleHandoffFailure()
        XCTAssertNil(state.appleHandoffFailure)
        XCTAssertEqual(state.authError, originalMessage)

        let nextID = UUID()
        state.configureAppleSignInRequest(ASAuthorizationAppleIDProvider().createRequest(), requestID: nextID)
        let untypedError = NSError(domain: "synthetic", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "[SCA177-H05] untrusted external message"
        ])
        await state.completeAppleSignIn(.failure(untypedError), requestID: nextID)
        XCTAssertNotNil(state.authError)
        XCTAssertNil(state.appleHandoffFailure, "A matching message prefix must not opt arbitrary errors into the support-code UI")
    }

    func testAppleHandoffFailureClearsOnAuthResetAccountChangeAndLogout() async throws {
        let state = AppState(client: Base44Client(), readStoredToken: { nil }, saveStoredToken: { _ in }, clearStoredToken: {})
        func failCurrentAttempt() async {
            let requestID = UUID()
            state.configureAppleSignInRequest(ASAuthorizationAppleIDProvider().createRequest(), requestID: requestID)
            await state.completeAppleSignIn(.failure(AppleNativeHandoffError.missingCallback), requestID: requestID)
            XCTAssertNotNil(state.appleHandoffFailure)
        }

        await failCurrentAttempt()
        state.authError = nil
        XCTAssertNil(state.appleHandoffFailure)

        await failCurrentAttempt()
        state.user = try JSONDecoder().decode(SpyUser.self, from: Data("{\"id\":\"synthetic-other-account\",\"email\":\"other@example.test\"}".utf8))
        XCTAssertNil(state.appleHandoffFailure)

        await failCurrentAttempt()
        state.logout()
        XCTAssertNil(state.appleHandoffFailure)
        XCTAssertNil(state.authError)
    }

    func testRenderedAppleFailureAlertShowsCompleteCodeAndActionsAfterToastExpires() async throws {
        let state = makeState()
        let previousLanguage = state.language
        defer { state.language = previousLanguage }
        state.language = .en
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AuthView()
            .spyGlobalToastLayer()
            .spyInterfaceScale()
            .environment(state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            state.dismissAppleHandoffFailure()
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        // Give SwiftUI its appearance pass before changing the observed state.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(host.view.window === window)

        let failure = AppleNativeHandoffError.missingCallback.withDiagnostic(
            AppleNativeHandoffDiagnostic(response: nil, destination: nil, redirectCount: 12)
        )
        let requestID = UUID()
        state.configureAppleSignInRequest(ASAuthorizationAppleIDProvider().createRequest(), requestID: requestID)
        // Inject a synthetic completed failure; never present or contact Apple.
        await state.completeAppleSignIn(.failure(failure), requestID: requestID)

        var renderedAlert: UIAlertController?
        for _ in 0..<100 {
            if let alert = host.presentedViewController as? UIAlertController,
               alert.viewIfLoaded?.window != nil, !alert.isBeingPresented {
                renderedAlert = alert
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let alert = try XCTUnwrap(renderedAlert, "The actual AuthView must present a native alert")
        XCTAssertEqual(alert.title, "Apple sign-in")
        XCTAssertEqual(alert.message, failure.localizedDescription)
        XCTAssertTrue(alert.message?.contains("SCA177-H05-r12-s0-cN-uUN-q0-pN-fN") == true)
        XCTAssertEqual(Set(alert.actions.compactMap(\.title)), ["Copy support code", "OK"])

        // The former transient toast lasts 2.8 seconds. The alert must remain
        // visible afterwards so the entire code can be read or copied.
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(state.toastNotices.isEmpty)
        XCTAssertTrue(host.presentedViewController === alert)
        XCTAssertNotNil(alert.view.window)
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(data: try XCTUnwrap(screenshot.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = "Apple-support-code-persistent-native-alert"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class AppleHandoffTestSession: SpyClash.WebAuthenticationSession {
    let completion: WebAuthenticationCoordinator.Completion
    var onStart: (() -> Void)?
    var cancelCount = 0
    init(completion: @escaping WebAuthenticationCoordinator.Completion) { self.completion = completion }
    func start() -> Bool { onStart?(); return true }
    func cancel() { cancelCount += 1 }
}

private final class AppleBootstrapURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (AppleBootstrapURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        handler(self)
    }
    override func stopLoading() {}
    func respond(body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
