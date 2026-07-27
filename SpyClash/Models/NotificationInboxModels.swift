import Foundation

enum NotificationInboxScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case global
    case personal

    var id: String { rawValue }
}

enum NotificationInboxImportance: String, Codable, CaseIterable, Identifiable, Sendable {
    case quiet
    case important

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self).lowercased()
        self = Self(rawValue: rawValue) ?? .quiet
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct NotificationInboxUnreadCounts: Codable, Equatable, Sendable {
    let global: Int
    let personal: Int

    static let zero = Self(global: 0, personal: 0)

    var total: Int { global + personal }

    init(global: Int, personal: Int) {
        self.global = max(0, global)
        self.personal = max(0, personal)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            global: try container.decodeIfPresent(Int.self, forKey: .global) ?? 0,
            personal: try container.decodeIfPresent(Int.self, forKey: .personal) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(global, forKey: .global)
        try container.encode(personal, forKey: .personal)
        try container.encode(total, forKey: .total)
    }

    func count(for scope: NotificationInboxScope) -> Int {
        switch scope {
        case .global: global
        case .personal: personal
        }
    }

    func replacing(_ scope: NotificationInboxScope, with count: Int) -> Self {
        switch scope {
        case .global:
            Self(global: count, personal: personal)
        case .personal:
            Self(global: global, personal: count)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case global
        case personal
        case total
    }
}

struct NotificationInboxItem: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let scope: NotificationInboxScope
    let kind: String
    let importance: NotificationInboxImportance
    let title: String
    let body: String
    let publishedAt: String
    let readAt: String?
    let actionDeepLink: String?

    var isUnread: Bool { readAt?.isEmpty != false }
    var isImportant: Bool { importance == .important }

    /// The Inbox itself is already the destination for notification links.
    /// Treating that fallback as a row action only renders an OPEN affordance
    /// that navigates back to the same screen.
    var actionableDeepLink: String? {
        guard let rawValue = actionDeepLink?.nilIfBlank,
              let components = URLComponents(string: rawValue),
              components.scheme?.nilIfBlank != nil else {
            return nil
        }

        if components.scheme?.lowercased() == "spyclash",
           components.host?.lowercased() == "notifications" {
            return nil
        }
        return rawValue
    }

    func markingRead(at timestamp: String) -> Self {
        Self(
            id: id,
            scope: scope,
            kind: kind,
            importance: importance,
            title: title,
            body: body,
            publishedAt: publishedAt,
            readAt: timestamp,
            actionDeepLink: actionDeepLink
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case scope
        case kind
        case importance
        case title
        case body
        case publishedAt = "published_at"
        case readAt = "read_at"
        case actionDeepLink = "action_deep_link"
    }
}

enum NotificationInboxTimestampParser {
    static func date(from rawValue: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: rawValue) {
            return date
        }

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return standardFormatter.date(from: rawValue)
    }
}

struct NotificationInboxSummary: Decodable, Equatable, Sendable {
    let ok: Bool
    let unread: NotificationInboxUnreadCounts
    let serverTime: String?

    init(
        ok: Bool = true,
        unread: NotificationInboxUnreadCounts,
        serverTime: String? = nil
    ) {
        self.ok = ok
        self.unread = unread
        self.serverTime = serverTime
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case unread
        case serverTime = "server_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        unread = try container.decode(NotificationInboxUnreadCounts.self, forKey: .unread)
        serverTime = try container.decodeIfPresent(String.self, forKey: .serverTime)
    }
}

struct NotificationInboxPage: Decodable, Equatable, Sendable {
    let ok: Bool
    let scope: NotificationInboxScope?
    let items: [NotificationInboxItem]
    let unread: NotificationInboxUnreadCounts
    let nextCursor: String?

    init(
        ok: Bool = true,
        scope: NotificationInboxScope? = nil,
        items: [NotificationInboxItem],
        unread: NotificationInboxUnreadCounts,
        nextCursor: String? = nil
    ) {
        self.ok = ok
        self.scope = scope
        self.items = items
        self.unread = unread
        self.nextCursor = nextCursor?.nilIfBlank
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case scope
        case items
        case unread
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        scope = try container.decodeIfPresent(NotificationInboxScope.self, forKey: .scope)
        items = try container.decodeIfPresent([NotificationInboxItem].self, forKey: .items) ?? []
        unread = try container.decode(NotificationInboxUnreadCounts.self, forKey: .unread)
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)?.nilIfBlank
    }
}

struct NotificationInboxMutationResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let item: NotificationInboxItem?
    let unread: NotificationInboxUnreadCounts

    init(
        ok: Bool = true,
        item: NotificationInboxItem? = nil,
        unread: NotificationInboxUnreadCounts
    ) {
        self.ok = ok
        self.item = item
        self.unread = unread
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case item
        case unread
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        item = try container.decodeIfPresent(NotificationInboxItem.self, forKey: .item)
        unread = try container.decode(NotificationInboxUnreadCounts.self, forKey: .unread)
    }
}

struct NotificationGlobalDraft: Equatable, Sendable {
    var requestID: UUID
    var title: String
    var body: String
    var importance: NotificationInboxImportance
    var actionDeepLink: String?

    init(
        requestID: UUID = UUID(),
        title: String = "",
        body: String = "",
        importance: NotificationInboxImportance = .quiet,
        actionDeepLink: String? = nil
    ) {
        self.requestID = requestID
        self.title = title
        self.body = body
        self.importance = importance
        self.actionDeepLink = actionDeepLink
    }
}

struct NotificationGlobalPublishResponse: Decodable, Equatable, Sendable {
    let ok: Bool
    let item: NotificationInboxItem
    let unread: NotificationInboxUnreadCounts?

    init(
        ok: Bool = true,
        item: NotificationInboxItem,
        unread: NotificationInboxUnreadCounts? = nil
    ) {
        self.ok = ok
        self.item = item
        self.unread = unread
    }

    enum CodingKeys: String, CodingKey {
        case ok
        case item
        case unread
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? true
        item = try container.decode(NotificationInboxItem.self, forKey: .item)
        unread = try container.decodeIfPresent(NotificationInboxUnreadCounts.self, forKey: .unread)
    }
}

enum NotificationInboxPreview {
    static let unread = NotificationInboxUnreadCounts(global: 2, personal: 1)

    static let globalItems = [
        NotificationInboxItem(
            id: "global:preview-important",
            scope: .global,
            kind: "announcement",
            importance: .important,
            title: "Operation window opened",
            body: "Cross-platform rooms are online. Update your field kit before the next mission.",
            publishedAt: "2026-07-27T08:15:00Z",
            readAt: nil,
            actionDeepLink: nil
        ),
        NotificationInboxItem(
            id: "global:preview-quiet",
            scope: .global,
            kind: "release_note",
            importance: .quiet,
            title: "Build 33",
            body: "Network stability and invitation delivery were improved.",
            publishedAt: "2026-07-26T18:40:00Z",
            readAt: nil,
            actionDeepLink: nil
        )
    ]

    static let personalItems = [
        NotificationInboxItem(
            id: "personal:preview-invite",
            scope: .personal,
            kind: "room_invite",
            importance: .important,
            title: "Room invitation",
            body: "RedRaven invited you to operation 844-010.",
            publishedAt: "2026-07-27T09:02:00Z",
            readAt: nil,
            actionDeepLink: "spyclash://community/invites"
        )
    ]

    static func page(for scope: NotificationInboxScope) -> NotificationInboxPage {
        NotificationInboxPage(
            scope: scope,
            items: scope == .global ? globalItems : personalItems,
            unread: unread
        )
    }
}
