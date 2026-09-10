import Foundation
import OSLog
import StoreKit

enum StoreKitOperationStage: String, Sendable {
    case appleSync = "APPLE"
    case localVerification = "VERIFY"
    case serverDelivery = "SERVER"
    case serverContract = "RESPONSE"
    case membershipRefresh = "ACCESS"
    case accessCheck = "STATUS"
    case reconciliation = "HISTORY"
}

enum StoreKitOperationOrigin: String, Sendable {
    case restore = "RESTORE", purchase = "BUY", activation = "ACTIVATE", update = "UPDATE"
}

enum StoreKitTransactionSource: String, Sendable {
    case none = "NONE", unfinished = "UNFINISHED", current = "CURRENT", latest = "LATEST"
}

enum AppStoreDeliveryError: Error { case responseRejected }

/// Only closed labels and numeric error codes can reach the UI or public logs.
/// Never retain a raw error, account/transaction identifiers, JWS, URLs or userInfo.
struct StoreKitOperationFailure: Error, Equatable, Sendable {
    let stage: StoreKitOperationStage
    let origin: StoreKitOperationOrigin
    let source: StoreKitTransactionSource
    let reason: String

    var supportCode: String {
        "IAP-\(origin.rawValue)-\(stage.rawValue)-\(source.rawValue): \(reason)"
    }

    private static let logger = Logger(subsystem: "com.spyclash.ios", category: "StoreKitOperation")

    func log() {
        Self.logger.error("Purchase operation failed code=\(supportCode, privacy: .public)")
    }

    static func capture(
        _ error: any Error,
        stage: StoreKitOperationStage,
        origin: StoreKitOperationOrigin,
        source: StoreKitTransactionSource = .none
    ) -> Self {
        // Preserve the innermost failing stage across the caller's catch blocks.
        if let failure = error as? Self { return failure }
        return Self(
            stage: error is AppStoreDeliveryError ? .serverContract : stage,
            origin: origin, source: source, reason: errorCode(error, depth: 0)
        )
    }

    private static func errorCode(_ error: any Error, depth: Int) -> String {
        guard depth < 3 else { return "NESTED" }
        if let verification = error as? VerificationResult<Transaction>.VerificationError {
            switch verification {
            case .revokedCertificate: return "CERT_REVOKED"
            case .invalidCertificateChain: return "CERT_CHAIN"
            case .invalidDeviceVerification: return "DEVICE_VERIFICATION"
            case .invalidEncoding: return "ENCODING"
            case .invalidSignature: return "SIGNATURE"
            case .missingRequiredProperties: return "MISSING_PROPERTIES"
            @unknown default: return "VERIFICATION_UNKNOWN"
            }
        }
        if let storeError = error as? StoreKitError {
            switch storeError {
            case .userCancelled: return "APPLE_CANCELLED"
            case .networkError(let underlying): return "NETWORK/" + errorCode(underlying, depth: depth + 1)
            case .systemError(let underlying): return "SYSTEM/" + errorCode(underlying, depth: depth + 1)
            case .notAvailableInStorefront: return "STOREFRONT"
            case .notEntitled: return "NOT_ENTITLED"
            default: return "STOREKIT_UNKNOWN"
            }
        }
        if let server = error as? Base44Error {
            let status = server.statusCode.map { String($0) } ?? "UNKNOWN"
            // Never include arbitrary server messages or machine-code strings.
            let bindingBusy = server.code == "apple_account_binding_busy" ? "/BINDING_BUSY" : ""
            return "HTTP_" + status + bindingBusy
        }
        if error is DecodingError { return "RESPONSE_DECODE" }
        if error is AppStoreDeliveryError { return "RESPONSE_REJECTED" }
        if let membership = error as? MembershipError {
            switch membership {
            case .unavailable: return "ACCESS_UNAVAILABLE"
            case .accountChanged: return "ACCOUNT_CHANGED"
            case .verificationFailed: return "VERIFICATION_FAILED"
            }
        }
        if error is CancellationError { return "CANCELLED" }
        let nsError = error as NSError
        let domain: String
        switch nsError.domain {
        case NSURLErrorDomain: domain = "URL"
        case NSCocoaErrorDomain: domain = "COCOA"
        case "SKErrorDomain": domain = "SK"
        case "ASDErrorDomain": domain = "ASD"
        case "AMSErrorDomain": domain = "AMS"
        default: domain = "OTHER"
        }
        let code = "\(domain)_\(nsError.code)"
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            return code + "/" + errorCode(underlying, depth: depth + 1)
        }
        return code
    }
}
