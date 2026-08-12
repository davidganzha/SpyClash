import AuthenticationServices
import CryptoKit
import Foundation
import Security

struct AppleSignInCredential: Encodable {
    let identityToken: String
    let authorizationCode: String
    let rawNonce: String
    let state: String
    let appleUserID: String
    let email: String?
    let givenName: String?
    let familyName: String?

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
        case authorizationCode = "authorization_code"
        case rawNonce = "raw_nonce"
        case state
        case appleUserID = "apple_user_id"
        case email
        case givenName = "given_name"
        case familyName = "family_name"
    }
}

@MainActor
final class AppleSignInCoordinator: NSObject {
    private var expectedState: String?
    private var rawNonce: String?

    func configure(_ request: ASAuthorizationAppleIDRequest) throws {
        guard expectedState == nil, rawNonce == nil else {
            throw AppleSignInError.requestAlreadyInProgress
        }

        let nonce = try Self.randomString()
        let state = try Self.randomString()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
        request.state = state

        rawNonce = nonce
        expectedState = state
    }

    func credential(
        from result: Result<ASAuthorization, any Error>
    ) throws -> AppleSignInCredential? {
        defer { clearRequestState() }

        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw AppleSignInError.unexpectedCredential
            }
            return try validatedCredential(from: credential)

        case .failure(let error):
            if let authorizationError = error as? ASAuthorizationError,
               authorizationError.code == .canceled {
                return nil
            }
            throw error
        }
    }

    func cancelPendingRequest() {
        clearRequestState()
    }

    private func validatedCredential(
        from credential: ASAuthorizationAppleIDCredential
    ) throws -> AppleSignInCredential {
        guard let expectedState,
              credential.state == expectedState else {
            throw AppleSignInError.stateMismatch
        }

        guard let rawNonce,
              let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8),
              !identityToken.isEmpty,
              let authorizationCodeData = credential.authorizationCode,
              let authorizationCode = String(data: authorizationCodeData, encoding: .utf8),
              !authorizationCode.isEmpty else {
            throw AppleSignInError.missingCredentialPayload
        }

        return AppleSignInCredential(
            identityToken: identityToken,
            authorizationCode: authorizationCode,
            rawNonce: rawNonce,
            state: expectedState,
            appleUserID: credential.user,
            email: credential.email,
            givenName: credential.fullName?.givenName,
            familyName: credential.fullName?.familyName
        )
    }

    private func clearRequestState() {
        expectedState = nil
        rawNonce = nil
    }

    private static func randomString(length: Int = 32) throws -> String {
        precondition(length > 0)

        let characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        let unbiasedLimit = 256 - (256 % characters.count)
        var result = [Character]()
        result.reserveCapacity(length)

        while result.count < length {
            var bytes = [UInt8](repeating: 0, count: length)
            let status = bytes.withUnsafeMutableBytes { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw AppleSignInError.randomGenerationFailed(status)
            }

            for byte in bytes where Int(byte) < unbiasedLimit {
                result.append(characters[Int(byte) % characters.count])
                if result.count == length { break }
            }
        }

        return String(result)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum AppleSignInError: LocalizedError {
    case requestAlreadyInProgress
    case randomGenerationFailed(OSStatus)
    case stateMismatch
    case missingCredentialPayload
    case unexpectedCredential

    var errorDescription: String? {
        if AppLanguage.stored == .uk {
            return switch self {
            case .requestAlreadyInProgress:
                "Вхід з Apple уже виконується."
            case .randomGenerationFailed:
                "Не вдалося захистити запит на вхід з Apple."
            case .stateMismatch:
                "Не вдалося перевірити стан входу з Apple. Спробуй ще раз."
            case .missingCredentialPayload:
                "Apple не повернув повні облікові дані для входу."
            case .unexpectedCredential:
                "Apple повернув непідтримувані облікові дані для входу."
            }
        }

        return switch self {
        case .requestAlreadyInProgress:
            "Apple sign-in is already in progress."
        case .randomGenerationFailed:
            "Unable to secure the Apple sign-in request."
        case .stateMismatch:
            "Apple sign-in state validation failed. Please try again."
        case .missingCredentialPayload:
            "Apple did not return a complete sign-in credential."
        case .unexpectedCredential:
            "Apple returned an unsupported sign-in credential."
        }
    }
}
