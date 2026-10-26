#if SPYCLASH_SUPABASE_TEST || SPYCLASH_SUPABASE
import Foundation
import Observation

/// Compatibility boundary for the original SpyClash UI. The full backend
/// projects GameRoom directly; the client never invents game state or roles.
@MainActor @Observable
final class SupabaseGameAdapter {
    static let shared = SupabaseGameAdapter()
    let store: SupabaseFullGameStore
    private(set) var user: SpyUser?
#if SPYCLASH_SUPABASE
    private var connectedGeneration: UUID?
    func connectSession(profile: SpyUser, restoreActiveRoom: Bool = true) async throws {
        let session = SupabaseAppSession.shared
        guard session.userID == profile.id else { throw SupabaseFullGameStore.notSignedIn }
        let generation = session.generation
        if connectedGeneration != generation {
            let shouldRestoreRoom = restoreActiveRoom &&
                (!session.isNativeGameCenterSession || !OnboardingProgressStore.shouldPresentOnboarding(for: profile))
            try await store.connect(transport: SupabaseAppGameTransport(auth: session), name: profile.callSign,
                                    restoreActiveRoom: shouldRestoreRoom)
            guard session.generation == generation, session.userID == profile.id else { throw CancellationError() }
            connectedGeneration = generation
        }
        guard session.generation == generation, session.userID == profile.id else { throw CancellationError() }
        user = profile
    }
#endif
    func disconnect() {
        store.disconnect(); user = nil
#if SPYCLASH_SUPABASE
        connectedGeneration = nil
#endif
    }

    init(store: SupabaseFullGameStore = SupabaseFullGameStore()) { self.store = store }
    var latestSnapshot: JSONValue { store.snapshot }
    var phase: String { store.phase }
    var currentRoom: GameRoom? { store.room }
    var hasPendingRecovery: Bool { store.hasPendingRecovery }
    var ownRoleConfirmed: Bool { store.room?.cardsReadList.contains(Self.alias(for: store.userID)) == true }
    static func alias(for userID: String) -> String { userID.lowercased() + "@example.test" }

    @discardableResult
    func connect(configurationURL: URL) async throws -> SpyUser {
        try await connect(JSONDecoder().decode(LabConfiguration.self, from: Data(contentsOf: configurationURL)))
    }

    @discardableResult
    func connect(_ configuration: LabConfiguration) async throws -> SpyUser {
        guard user == nil else { throw Base44Error(message: "Restart the test app to change account.", code: "restart_test_app_to_change_account") }
        try await store.connect(configuration)
        let value: JSONValue = .object([
            "id": .string(store.userID), "email": .string(Self.alias(for: store.userID)),
            "display_name": .string(configuration.name), "avatar": .string("🕵️"),
            "onboarding_completed": .bool(true), "onboarding_version": .number(Double(OnboardingSubmission.currentVersion)),
            "is_verified": .bool(true)
        ])
        let connected = try JSONDecoder().decode(SpyUser.self, from: value.data())
        user = connected
        return connected
    }

    func roomAction(_ body: [String: JSONValue]) async throws -> GameRoom {
        if body["action"]?.string == "get_room", let id = body["room_id"]?.string {
            guard let room = try await refreshRoom(id: id) else { throw Self.roomMissing }
            return room
        }
        let response = try await store.command(body)
        guard let candidate = currentRoom, response["room"].isNull || response["room"]["id"].string == candidate.id else {
            throw Self.roomMissing
        }
        return candidate
    }

    func refreshRoom(id: String) async throws -> GameRoom? { try await store.refreshRoom(id: id) }
    func activeRoom(preferredRoomID: String?) async throws -> GameRoom? { try await store.refreshActiveRoom(preferredRoomID: preferredRoomID) }
    @discardableResult
    func retryPending() async throws -> GameRoom? { try await store.retryPending() }
    func retrySavedCommand() async throws -> JSONValue { try await store.retryPendingResponse() }

    func leaveRoom(roomID: String, membershipID: String?, expectedRevision: Int? = nil) async throws {
        var body: [String: JSONValue] = ["action": .string("leave_room"), "room_id": .string(roomID)]
        if let membershipID { body["expected_membership_id"] = .string(membershipID) }
        if let expectedRevision { body["expected_revision"] = .number(Double(expectedRevision)) }
        _ = try await store.command(body)
    }

    func closeRoom(roomID: String, membershipID: String? = nil, expectedRevision: Int? = nil) async throws {
        var body: [String: JSONValue] = ["action": .string("close_room"), "room_id": .string(roomID)]
        if let membershipID { body["expected_membership_id"] = .string(membershipID) }
        if let expectedRevision { body["expected_revision"] = .number(Double(expectedRevision)) }
        _ = try await store.command(body)
    }

    func wordPackAction(_ action: String, packID: String?, name: String?, category: String?, words: [String]?) async throws -> JSONValue {
        let actions = ["list": "word_packs", "create": "create_word_pack", "update": "update_word_pack", "delete": "delete_word_pack"]
        guard let operation = actions[action] else { throw Base44Error(message: "Unknown word-pack action.", code: "invalid_action") }
        var body: [String: JSONValue] = ["action": .string(operation)]
        if let packID { body["pack_id"] = .string(packID) }
        if let name { body["name"] = .string(name) }
        if let category { body["category"] = .string(category) }
        if let words { body["words"] = .array(words.map(JSONValue.string)) }
        return action == "list" ? try await store.read(body) : try await store.command(body)
    }

    func generateWordPack(theme: String, count: Int, requestID: UUID, excluding: [String], preferFresh: Bool) async throws -> GeneratedWordPack {
#if SPYCLASH_SUPABASE
        let session = SupabaseAppSession.shared
        let generation = session.generation
        let actorID = session.userID
        func requireCurrentAccount() throws {
            try Task.checkCancellation()
            guard session.generation == generation, session.userID == actorID else { throw CancellationError() }
        }
        let capability: JSONValue = try await session.service("legacy", action: "status")
        try requireCurrentAccount()
        guard capability["configured"].bool else {
            throw Base44Error(message: "The word generator is temporarily unavailable. Use a saved or manual word pack.", statusCode: 503, code: "legacy_bridge_unconfigured")
        }
        // Missing capability data keeps the existing Base44 credential route.
        // Only an explicit server capability enables native generation.
        let requiresLegacySession = capability["requires_legacy_session"] != .bool(false)
        if requiresLegacySession && !capability["linked"].bool {
            let _: JSONValue = try await session.service("legacy", action: "link", write: true, includeLegacyCredential: true)
            try requireCurrentAccount()
        }
        return try await session.service("legacy", action: "generate", fields: Self.generationFields(theme: theme, count: count, requestID: requestID, excluding: excluding, preferFresh: preferFresh), write: true, includeLegacyCredential: requiresLegacySession)
#else
        // The generator remains on Base44. Synthetic Supabase test identities
        // have no Base44 session, and must never trigger a production request.
        throw Base44Error(message: "Генератор остаётся на Base44 и требует входа в аккаунт Base44. В тестовой сборке используйте сохранённый или ручной набор слов.", statusCode: 403, code: "base44_generation_requires_auth")
#endif
    }

    static func generationFields(theme: String, count: Int, requestID: UUID, excluding: [String], preferFresh: Bool) -> [String: JSONValue] {
        ["theme": .string(theme), "count": .number(Double(count)), "request_id": .string(requestID.uuidString.lowercased()),
         "exclude_words": .array(excluding.map(JSONValue.string)), "prefer_fresh": .bool(preferFresh)]
    }

    private static var roomMissing: Base44Error { Base44Error(message: "Room not found.", statusCode: 404, code: "room_not_found") }
}
#endif
