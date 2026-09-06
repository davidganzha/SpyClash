import AuthenticationServices
import Foundation
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
}
