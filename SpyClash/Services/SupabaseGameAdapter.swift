#if SPYCLASH_SUPABASE_TEST
import Foundation
import Observation

/// Staging-only bridge into the actual SpyClash models. The server remains the
/// authority for membership, phase, votes and each viewer's private role.
@MainActor @Observable
final class SupabaseGameAdapter {
    static let shared = SupabaseGameAdapter()
    private(set) var store = LabStore()
    private(set) var user: SpyUser?
    private var confirmedRoleMatchID: String?
    private var committedReads: [CommittedRead] = []
    private var commandInFlight = false

    private struct CommittedRead: Codable {
        let actorID: String
        let roomID: String
        let action: String
        let payload: JSONValue
        let receipt: JSONValue
    }

    var latestSnapshot: JSONValue { store.snapshot }
    var phase: String { store.phase }
    /// Both ambiguous commands and acknowledged commands awaiting a fresh read
    /// require recovery before the UI accepts another mutation.
    var hasPendingRecovery: Bool { !store.pendingIDs.isEmpty || !committedReads.isEmpty }
    var ownRoleConfirmed: Bool {
        guard let match = latestSnapshot["match_id"].string else { return false }
        return confirmedRoleMatchID == match
    }
    var currentRoom: GameRoom? { phase == "closed" ? nil : try? project(latestSnapshot) }

    static func alias(for userID: String) -> String { userID.lowercased() + "@example.test" }

    @discardableResult
    func connect(configurationURL: URL) async throws -> SpyUser {
        let configuration = try JSONDecoder().decode(LabConfiguration.self, from: Data(contentsOf: configurationURL))
        return try await connect(configuration)
    }

    @discardableResult
    func connect(_ configuration: LabConfiguration) async throws -> SpyUser {
        guard user == nil else {
            throw LabFailure(code: "restart_test_app_to_change_account")
        }
        // LabStore.connect writes fresh evidence. Capture the previous room
        // first, then authorize its restoration against the new Auth identity.
        let prior = (try? Data(contentsOf: evidenceURL("state.json")))
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        try await store.connect(configuration)
        committedReads = ((try? Data(contentsOf: evidenceURL("committed-read-recovery.json")))
            .flatMap { try? JSONDecoder().decode([CommittedRead].self, from: $0) } ?? [])
            .filter { $0.actorID == store.userID }
        let value: JSONValue = .object([
            "id": .string(store.userID), "email": .string(Self.alias(for: store.userID)),
            "display_name": .string(configuration.name), "avatar": .string("🕵️"),
            "onboarding_completed": .bool(true), "onboarding_version": .number(Double(OnboardingSubmission.currentVersion)),
            "is_verified": .bool(true)
        ])
        let connected = try JSONDecoder().decode(SpyUser.self, from: value.data())
        user = connected
        let restoreID = prior?["user_id"].string == store.userID ? prior?["room_id"].string : nil
        if let restoreID, UUID(uuidString: restoreID) != nil {
            do {
                if try await refreshRoom(id: restoreID) != nil { try await store.watch(room: restoreID) }
            } catch {
                // An authenticated user can still enter the app while offline.
                // Keep durable pending intents and expose the retryable failure.
                store.lastError = safeFailure(error).code
            }
        }
        return connected
    }

    func createRoom() async throws -> GameRoom {
        let pendingCreate = store.pending.values.first { $0.actorID == store.userID && $0.action == "create_room" }
        let roomID = pendingCreate?.roomID ?? committedReads.first(where: { $0.action == "create_room" })?.roomID ?? UUID().uuidString.lowercased()
        return try await perform(roomID: roomID, action: "create_room", payload: [
            "name": .string(store.name), "settings": .object(["max_players": .number(12)])
        ])
    }

    func joinRoom(code: String) async throws -> GameRoom {
        guard let id = UUID(uuidString: code.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LabFailure(code: "enter_test_room_uuid")
        }
        let roomID = id.uuidString.lowercased()
        if let pending = pendingIntent(roomID: roomID, action: "join_room") {
            return try await perform(roomID: roomID, action: "join_room", payload: pending.source["payload"].object ?? [:])
        }
        guard !hasPendingRecovery, !commandInFlight else {
            throw LabFailure(code: "pending_command_requires_retry", ambiguous: true)
        }
        do {
            // Existing membership survives the app process and remains valid
            // outside the lobby. Read it before attempting a lobby-only join.
            // Transport failures must not turn this read into a new mutation.
            let snapshot = try await store.refresh(room: roomID, activate: true)
            guard snapshot["room_id"].string == roomID, snapshot["phase"].string != "closed" else {
                throw LabFailure(code: "room_not_available")
            }
            await restoreWatchIfNeeded(roomID: roomID, action: "join_room")
            guard let current = currentRoom, current.id == roomID else {
                throw LabFailure(code: "room_not_available")
            }
            return current
        } catch let error as LabFailure where ["not_member", "room_not_found"].contains(error.code) {
            return try await perform(roomID: roomID, action: "join_room", payload: ["name": .string(store.name)])
        }
    }

    func refreshRoom(id: String) async throws -> GameRoom? {
        let generation = store.roomContextGeneration
        let membership = store.snapshot["own_membership_id"].string
        do {
            let snapshot = try await store.refresh(room: id.lowercased())
            if snapshot["phase"].string == "closed" {
                // A closed authoritative snapshot is also a completed read.
                // Keeping its earlier receipt here would strand Home in Retry.
                if snapshot["room_id"].string == id.lowercased() {
                    committedReads.removeAll {
                        $0.roomID == id.lowercased() && snapshot["revision"].integer >= $0.receipt["revision"].integer
                    }
                    persistCommittedReads()
                }
                return nil
            }
            return try project(snapshot)
        } catch let error as LabFailure where ["not_member", "room_not_found"].contains(error.code) {
            store.clearCurrentRoomAfterMembershipLoss(roomID: id.lowercased(), expectedGeneration: generation, expectedMembershipID: membership)
            committedReads.removeAll { $0.roomID == id.lowercased() }
            persistCommittedReads()
            return nil
        }
    }

    func activeRoom(preferredRoomID: String?) async throws -> GameRoom? {
        guard let id = preferredRoomID ?? store.roomID else { return nil }
        return try await refreshRoom(id: id)
    }

    func setReady(_ ready: Bool, roomID: String? = nil) async throws -> GameRoom {
        try await perform(roomID: try requireRoomID(roomID), action: "set_ready", payload: ["ready": .bool(ready)])
    }

    func toggleReady(roomID: String) async throws -> GameRoom {
        if let pending = pendingIntent(roomID: roomID, action: "set_ready") {
            return try await perform(roomID: roomID, action: "set_ready", payload: pending.source["payload"].object ?? [:])
        }
        return try await setReady(!store.ownReady, roomID: roomID)
    }

    func startGame(roomID: String) async throws -> GameRoom {
        try await perform(roomID: roomID, action: "start_game")
    }

    func openVoting(roomID: String) async throws -> GameRoom {
        try await perform(roomID: roomID, action: "open_voting")
    }

    func vote(roomID: String, targetEmail: String) async throws -> GameRoom {
        guard targetEmail.lowercased().hasSuffix("@example.test"),
              let id = UUID(uuidString: String(targetEmail.dropLast("@example.test".count))) else {
            throw LabFailure(code: "invalid_target")
        }
        return try await perform(roomID: roomID, action: "vote", payload: ["target_id": .string(id.uuidString.lowercased())])
    }

    func returnToLobby(roomID: String) async throws -> GameRoom {
        try await perform(roomID: roomID, action: "return_to_lobby")
    }

    func confirmOwnRole(roomID: String) throws -> GameRoom {
        guard latestSnapshot["room_id"].string == roomID.lowercased(),
              let match = latestSnapshot["match_id"].string,
              latestSnapshot["own_role"].string != nil else { throw LabFailure(code: "role_not_available") }
        confirmedRoleMatchID = match
        return try project(latestSnapshot)
    }

    @discardableResult
    func confirmOwnRole() throws -> GameRoom {
        try confirmOwnRole(roomID: requireRoomID(nil))
    }

    @discardableResult
    func retryPending() async throws -> GameRoom? {
        let pending = store.pendingIDs.compactMap { store.pending[$0] }
        for intent in pending {
            if ["leave_room", "close_room"].contains(intent.action) {
                _ = try await store.retry(requestID: intent.requestID)
            } else {
                _ = try await perform(roomID: intent.roomID, action: intent.action, payload: intent.source["payload"].object ?? [:])
            }
        }
        for read in committedReads {
            if try await refreshRoom(id: read.roomID) == nil {
                continue
            }
            if store.snapshot["room_id"].string == read.roomID,
               store.snapshot["revision"].integer >= read.receipt["revision"].integer {
                await restoreWatchIfNeeded(roomID: read.roomID, action: read.action)
                committedReads.removeAll { $0.roomID == read.roomID && $0.action == read.action }
            }
        }
        persistCommittedReads()
        if let room = store.roomID { _ = try await store.refresh(room: room) }
        return currentRoom
    }

    func leaveRoom(roomID: String, membershipID: String?) async throws {
        var payload: [String: JSONValue] = [:]
        if let membershipID { payload["membership_id"] = .string(membershipID) }
        _ = try await commit(roomID: roomID, action: "leave_room", payload: payload)
    }

    func closeRoom(roomID: String) async throws {
        _ = try await commit(roomID: roomID, action: "close_room", payload: [:])
    }

    /// Preserve the exact durable intent after ambiguous transport failure. A
    /// changed UI intent cannot silently replace an unresolved command.
    private func commit(roomID: String, action: String, payload: [String: JSONValue]) async throws -> JSONValue {
        let roomID = roomID.lowercased()
        if let pending = pendingIntent(roomID: roomID, action: action) {
            guard pending.source["payload"] == .object(payload) else {
                throw LabFailure(code: "pending_command_requires_retry", ambiguous: true)
            }
            return try await store.retry(requestID: pending.requestID)
        }
        guard !hasPendingRecovery, !commandInFlight else {
            throw LabFailure(code: "pending_command_requires_retry", ambiguous: true)
        }
        commandInFlight = true
        defer { commandInFlight = false }
        return try await store.command(room: roomID, action: action, payload: .object(payload))
    }

    private func perform(roomID: String, action: String, payload: [String: JSONValue] = [:]) async throws -> GameRoom {
        let roomID = roomID.lowercased()
        let receipt: JSONValue
        if let recovery = committedReads.first(where: { $0.roomID == roomID && $0.action == action }) {
            guard recovery.payload == .object(payload) else { throw LabFailure(code: "pending_command_requires_retry", ambiguous: true) }
            receipt = recovery.receipt
            _ = try await store.refresh(room: roomID)
        } else {
            receipt = try await commit(roomID: roomID, action: action, payload: payload)
            committedReads.append(CommittedRead(actorID: store.userID, roomID: roomID, action: action, payload: .object(payload), receipt: receipt))
            persistCommittedReads()
        }
        guard store.snapshot["room_id"].string == roomID,
              store.snapshot["revision"].integer >= receipt["revision"].integer else {
            // The receipt is already durable; a failed follow-up read must not
            // create a new command. Leave retry to snapshot reconciliation.
            throw LabFailure(code: "committed_awaiting_snapshot", ambiguous: true)
        }
        await restoreWatchIfNeeded(roomID: roomID, action: action)
        committedReads.removeAll { $0.roomID == roomID && $0.action == action }
        persistCommittedReads()
        return try project(store.snapshot)
    }

    private func restoreWatchIfNeeded(roomID: String, action: String) async {
        guard ["create_room", "join_room"].contains(action),
              store.watchedRoomID != roomID || store.realtime != "subscribed" else { return }
        do { try await store.watch(room: roomID) }
        catch { store.lastError = safeFailure(error).code }
    }

    private func evidenceURL(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Evidence", isDirectory: true).appendingPathComponent(name)
    }

    private func persistCommittedReads() {
        if let data = try? JSONEncoder().encode(committedReads) {
            try? data.write(to: evidenceURL("committed-read-recovery.json"), options: .atomic)
        }
    }

    private func pendingIntent(roomID: String, action: String) -> LabStore.Intent? {
        store.pending.values.first { $0.actorID == store.userID && $0.roomID == roomID.lowercased() && $0.action == action }
    }

    private func requireRoomID(_ supplied: String?) throws -> String {
        guard let id = supplied ?? store.roomID else { throw LabFailure(code: "room_not_found") }
        return id
    }

    private func project(_ snapshot: JSONValue) throws -> GameRoom {
        guard let id = snapshot["room_id"].string, let phase = snapshot["phase"].string else {
            throw LabFailure(code: "room_snapshot_unavailable")
        }
        let players = snapshot["players"].array.map { player -> JSONValue in
            .object(["email": .string(Self.alias(for: player["user_id"].string ?? "")),
                     "user_id": player["user_id"], "membership_id": player["membership_id"],
                     "name": player["name"], "avatar": .string("🕵️")])
        }
        let ready = snapshot["players"].array.filter { $0["ready"].bool }.map { JSONValue.string(Self.alias(for: $0["user_id"].string ?? "")) }
        let votes = snapshot["votes"].array.map { vote -> JSONValue in
            .object(["voter_email": .string(Self.alias(for: vote["voter_id"].string ?? "")),
                     "voted_for_email": .string(Self.alias(for: vote["target_id"].string ?? ""))])
        }
        let status = ["lobby": "waiting", "playing": "playing", "voting": "playing", "finished": "finished", "closed": "ended"][phase] ?? phase
        let winner: JSONValue = snapshot["winner"].string.map { .string($0 == "spies" ? "spy" : "detective") } ?? .null
        let ownSpy: [JSONValue] = snapshot["own_role"].string == "spy" ? [.string(Self.alias(for: store.userID))] : []
        let ownRead: [JSONValue] = confirmedRoleMatchID != nil && confirmedRoleMatchID == snapshot["match_id"].string ? [.string(Self.alias(for: store.userID))] : []
        let room: JSONValue = .object([
            "id": .string(id), "code": .string(id), "status": .string(status),
            "viewer_membership_id": snapshot["own_membership_id"],
            "host_email": snapshot["host_id"].string.map { .string(Self.alias(for: $0)) } ?? .null,
            "players": .array(players), "match_id": snapshot["match_id"],
            "room_revision": snapshot["revision"], "lobby_revision": snapshot["settings_revision"],
            "ready_players": .array(ready), "detective_votes": .array(votes),
            "detective_vote_round_id": phase == "voting" ? snapshot["match_id"] : .null,
            "spy_emails": .array(ownSpy), "secret_word": snapshot["own_word"],
            "cards_read": .array(ownRead), "winner": winner
        ])
        return try JSONDecoder().decode(GameRoom.self, from: room.data())
    }
}
#endif
