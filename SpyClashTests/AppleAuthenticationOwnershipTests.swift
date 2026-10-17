import AuthenticationServices
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import SpyClash

@MainActor
final class AppleAuthenticationOwnershipTests: XCTestCase {
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
