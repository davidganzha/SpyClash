import Foundation

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
                (isUniversal || providers.contains(where: { ["apple", "stripe", "admin"].contains($0) }))
        }
        return tier == .free && ["inactive", "free"].contains(status)
    }

    static let universalPreview = Self(active: true, tier: .limitless, status: "active", accessProtocol: "casada", providers: ["casada"], benefits: .limitless, expiresAt: nil, aiGenerationsToday: nil, aiRemaining: nil, checkoutRequired: false)
    static let freePreview = Self(active: false, tier: .free, status: "inactive", accessProtocol: "limitless", providers: [], benefits: .free, expiresAt: nil, aiGenerationsToday: 3, aiRemaining: 7, checkoutRequired: false)
}

struct MembershipScope: Equatable {
    let userID: String?
    let accessToken: String?
    var isAuthenticated: Bool { userID?.isEmpty == false && accessToken?.isEmpty == false }
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
