import Foundation

/// A membership read may fail before StoreKit starts. Retain only bounded,
/// closed diagnostics, never provider messages, credentials or response bodies.
struct MembershipRefreshFailure: Error, Equatable, Sendable {
    enum Reason: String, Sendable {
        case sessionMissing = "SESSION_MISSING"
        case sessionInvalid = "SESSION_INVALID"
        case wrongProvider = "WRONG_PROVIDER"
        case accountMismatch = "ACCOUNT_MISMATCH"
        case billingUnconfigured = "BILLING_UNCONFIGURED"
        case billingUnavailable = "BILLING_UNAVAILABLE"
        case billingRejected = "BILLING_REJECTED"
        case billingResponseInvalid = "BILLING_RESPONSE_INVALID"
        case providerResponseInvalid = "PROVIDER_RESPONSE_INVALID"
        case identityUnavailable = "IDENTITY_UNAVAILABLE"
        case identityInvalid = "IDENTITY_INVALID"
        case serviceUnavailable = "SERVICE_UNAVAILABLE"
        case transportInterrupted = "TRANSPORT_INTERRUPTED"
        case server = "SERVER"
        case responseDecode = "RESPONSE_DECODE"
        case unresolvedAccess = "UNRESOLVED_ACCESS"
        case accountChanged = "ACCOUNT_CHANGED"
        case verificationFailed = "VERIFICATION_FAILED"
        case network = "NETWORK"
        case networkOffline = "NETWORK_OFFLINE"
        case networkTimeout = "NETWORK_TIMEOUT"
        case unknown = "UNKNOWN"
    }

    let reason: Reason
    let httpStatus: Int?

    var supportReason: String {
        let status = httpStatus.map { "/HTTP_\($0)" } ?? ""
        return "ACCESS_UNVERIFIED\(status)/\(reason.rawValue)"
    }

    static func capture(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        if let server = error as? Base44Error {
            let reason: Reason
            switch server.code {
            case "legacy_session_missing", "legacy_session_required", "supabase_session_missing": reason = .sessionMissing
            case "legacy_session_invalid", "legacy_session_revalidation_required", "jwt_expired": reason = .sessionInvalid
            case "wrong_credential_provider": reason = .wrongProvider
            case "legacy_owner_mismatch": reason = .accountMismatch
            case "legacy_billing_unconfigured": reason = .billingUnconfigured
            case "legacy_billing_unavailable": reason = .billingUnavailable
            case "legacy_billing_rejected": reason = .billingRejected
            case "legacy_billing_response_invalid": reason = .billingResponseInvalid
            case "legacy_response_invalid": reason = .providerResponseInvalid
            case "legacy_verification_unavailable": reason = .identityUnavailable
            case "legacy_identity_invalid": reason = .identityInvalid
            case "app_service_unavailable": reason = .serviceUnavailable
            case "supabase_transport_interrupted": reason = .transportInterrupted
            default: reason = .server
            }
            let status = server.statusCode.flatMap { (100...599).contains($0) ? $0 : nil }
            return Self(reason: reason, httpStatus: status)
        }
        if error is DecodingError { return Self(reason: .responseDecode, httpStatus: nil) }
        if let membership = error as? MembershipError {
            let reason: Reason
            switch membership {
            case .unavailable: reason = .unresolvedAccess
            case .accountChanged: reason = .accountChanged
            case .verificationFailed: reason = .verificationFailed
            }
            return Self(reason: reason, httpStatus: nil)
        }
        let system = error as NSError
        if system.domain == NSURLErrorDomain {
            let reason: Reason
            switch system.code {
            case URLError.notConnectedToInternet.rawValue: reason = .networkOffline
            case URLError.timedOut.rawValue: reason = .networkTimeout
            default: reason = .network
            }
            return Self(reason: reason, httpStatus: nil)
        }
        return Self(reason: .unknown, httpStatus: nil)
    }
}

enum MembershipTier: String, Codable { case free, limitless }

struct MembershipBenefits: Codable, Equatable, Sendable {
    let aiGenerationsDailyLimit: Int?
    let premiumAvatars: Bool
    let fullHistory: Bool
    let advancedStatistics: Bool
    let historyLimit: Int?

    static let free = Self(aiGenerationsDailyLimit: 10, premiumAvatars: false, fullHistory: false, advancedStatistics: false, historyLimit: 5)
    static let limitless = Self(aiGenerationsDailyLimit: nil, premiumAvatars: true, fullHistory: true, advancedStatistics: true, historyLimit: nil)

    enum CodingKeys: String, CodingKey {
        case aiGenerationsDailyLimit = "ai_generations_daily_limit"
        case premiumAvatars = "premium_avatars"
        case fullHistory = "full_history"
        case advancedStatistics = "advanced_statistics"
        case historyLimit = "history_limit"
    }
}

struct MembershipSnapshot: Decodable, Equatable {
    let active: Bool
    let tier: MembershipTier
    let status: String
    let accessProtocol: String?
    let providers: [String]
    let benefits: MembershipBenefits
    let expiresAt: Date?
    var aiGenerationsToday: Int?
    var aiRemaining: Int?
    let checkoutRequired: Bool?

    enum CodingKeys: String, CodingKey {
        case active, tier, status, providers, benefits
        case accessProtocol = "protocol"
        case expiresAt = "expires_at"
        case aiGenerationsToday = "ai_generations_today"
        case aiRemaining = "ai_remaining"
        case checkoutRequired = "apple_purchase_enabled"
    }

    var isUniversal: Bool {
        active && accessProtocol == "casada" && providers.contains("casada")
    }

    func grantsAccess(at now: Date = Date()) -> Bool {
        guard active, tier == .limitless, ["active", "trialing", "grace_period"].contains(status) else { return false }
        if isUniversal { return true }
        guard providers.contains(where: { ["apple", "stripe", "admin"].contains($0) }) else { return false }
        if providers.contains("admin"), expiresAt == nil { return true }
        return expiresAt.map { $0 > now } ?? false
    }

    // Unknown/malformed states must not turn an outage into a purchase offer.
    var isResolved: Bool {
        if active {
            return tier == .limitless &&
                ["active", "trialing", "grace_period"].contains(status) &&
                (isUniversal ||
                    (providers.contains(where: { ["apple", "stripe", "admin"].contains($0) }) &&
                        (expiresAt != nil || providers.contains("admin"))))
        }
        return tier == .free && ["inactive", "free"].contains(status)
    }

    static let universalPreview = Self(active: true, tier: .limitless, status: "active", accessProtocol: "casada", providers: ["casada"], benefits: .limitless, expiresAt: nil, aiGenerationsToday: nil, aiRemaining: nil, checkoutRequired: false)
    static let freePreview = Self(active: false, tier: .free, status: "inactive", accessProtocol: "limitless", providers: [], benefits: .free, expiresAt: nil, aiGenerationsToday: 3, aiRemaining: 7, checkoutRequired: false)
}

struct MembershipScope: Equatable {
    let userID: String?
    let accessToken: String?
    let sessionGeneration: UUID?

    init(userID: String?, accessToken: String?, sessionGeneration: UUID? = nil) {
        self.userID = userID
        self.accessToken = accessToken
        self.sessionGeneration = sessionGeneration
    }

    var isAuthenticated: Bool { userID?.isEmpty == false && accessToken?.isEmpty == false }

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.userID == rhs.userID, lhs.isAuthenticated == rhs.isAuthenticated else { return false }
        if lhs.sessionGeneration != nil || rhs.sessionGeneration != nil {
            return lhs.sessionGeneration == rhs.sessionGeneration
        }
        return lhs.accessToken == rhs.accessToken
    }

    func matchesSession(accessToken: String?, generation: UUID?) -> Bool {
        guard isAuthenticated, accessToken?.isEmpty == false else { return false }
        // Supabase refresh rotates the bearer without replacing the signed-in
        // account. Logout, replacement login and account switching rotate this
        // generation, so late StoreKit responses still cannot cross sessions.
        if let sessionGeneration { return sessionGeneration == generation }
        return self.accessToken == accessToken
    }
}

struct MembershipActivityScope: Equatable {
    let account: MembershipScope
    let active: Bool
}

enum LimitlessProfilePolicy {
    static let freeAvatars = Set(["🕵️", "🥷", "🧠", "🎭", "🦅"])

    static func allows(_ value: String, current: String?, freeValues: Set<String>, hasAccess: Bool) -> Bool {
        hasAccess || freeValues.contains(value) || value == current
    }
}
