#if SPYCLASH_SUPABASE_TEST || SPYCLASH_SUPABASE
import Foundation
import Observation

@MainActor
protocol SupabaseFullGameTransport: AnyObject {
    var userID: String { get }
    var onRealtime: ((String, JSONValue?) -> Void)? { get set }
    func fullGame(_ body: JSONValue) async throws -> JSONValue
    func watch(roomID: String, table: String) async throws
    func disconnectRealtime()
}

struct FullGameTransportFailure: Error {
    let error: Base44Error
    let ambiguous: Bool
}

/// The full-game test target has its own state and durable command journal.
/// Neither a read, reconnect nor UI retry can rebind an unresolved command.
@MainActor @Observable
final class SupabaseFullGameStore {
    struct Intent: Codable, Equatable {
        let requestID: String
        let actorID: String
        let source: JSONValue
        let body: JSONValue
        var acknowledgement: JSONValue?
    }
    private struct SavedState: Codable {
        let actorID: String
        let roomID: String?
        let snapshot: JSONValue
        let pending: Intent?
    }

    private(set) var userID: String
    private(set) var name: String
    private(set) var snapshot: JSONValue = .null
    private(set) var room: GameRoom?
    private(set) var roomID: String?
    private(set) var pending: Intent?
    private(set) var realtime = "disconnected"
    private(set) var lastError = ""
    private(set) var lastReceipt: JSONValue = .null
    private(set) var signalRevisions: [Int] = []
    private(set) var commandInFlight = false
    @ObservationIgnored private var transport: (any SupabaseFullGameTransport)?
    @ObservationIgnored private let evidenceDirectory: URL
    @ObservationIgnored private let automaticallyWatches: Bool
    @ObservationIgnored private var roomEpoch = 0
    @ObservationIgnored private var transportEpoch = 0
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var watchedRoomID: String?
    @ObservationIgnored private var refreshInFlight = false

    var hasPendingRecovery: Bool { pending != nil }
    var phase: String { room?.normalizedStatus ?? "idle" }
    var roomContextGeneration: Int { roomEpoch }
    var pendingIDs: [String] { pending.map { [$0.requestID] } ?? [] }

    init(transport: (any SupabaseFullGameTransport)? = nil, actorID: String = "", name: String = "Player", evidenceDirectory: URL? = nil, automaticallyWatches: Bool = true) {
        self.automaticallyWatches = automaticallyWatches
        self.transport = transport
        self.userID = actorID
        self.name = name
        self.evidenceDirectory = evidenceDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SupabaseFullGame", isDirectory: true)
        if !actorID.isEmpty { restoreJournal() }
    }

    func connect(_ configuration: LabConfiguration) async throws {
        let backend = try BackendClient(config: configuration)
        try await backend.signIn()
        try await connect(transport: backend, name: configuration.name)
    }

    func disconnect() {
        transportEpoch += 1
        roomEpoch += 1
        reconciliationTask?.cancel(); reconciliationTask = nil
        stopWatch()
        transport = nil; userID = ""; name = "Player"
        room = nil; roomID = nil; snapshot = .null; pending = nil
        lastError = ""; lastReceipt = .null; signalRevisions = []
        commandInFlight = false; refreshInFlight = false
    }

    func connect(transport backend: any SupabaseFullGameTransport, name: String) async throws {
        disconnect()
        transport = backend
        userID = backend.userID
        self.name = name
        restoreJournal()
        let connectionEpoch = transportEpoch
        backend.onRealtime = { [weak self] event, value in
            guard let self, self.transportEpoch == connectionEpoch else { return }
            self.realtime = event == "signal" ? self.realtime : event
            if event == "signal", let value, value["room_id"].string == self.roomID {
                self.signalRevisions.append(value["revision"].integer)
                self.signalRevisions = Array(self.signalRevisions.suffix(100))
                Task { await self.reconcile() }
            }
            self.persistEvidence()
        }
        do { _ = try await refreshActiveRoom(preferredRoomID: roomID) }
        catch {
            guard connectionEpoch == transportEpoch, userID == backend.userID else { throw CancellationError() }
            lastError = Self.failure(error).error.code ?? "room_restore_failed"
        }
        guard connectionEpoch == transportEpoch, userID == backend.userID else { throw CancellationError() }
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await self?.reconcile()
            }
        }
    }

    func read(_ body: [String: JSONValue]) async throws -> JSONValue {
        guard let transport, !userID.isEmpty else { throw Self.notSignedIn }
        do { return try await transport.fullGame(.object(body)) }
        catch { throw Self.failure(error).error }
    }

    func refreshActiveRoom(preferredRoomID: String?) async throws -> GameRoom? {
        var body: [String: JSONValue] = ["action": .string("get_active_room")]
        if let preferredRoomID { body["room_id"] = .string(preferredRoomID) }
        return try await readRoom(body, expectedRoomID: preferredRoomID, activates: true)
    }

    func refreshRoom(id: String, activates: Bool = false) async throws -> GameRoom? {
        try await readRoom(["action": .string("get_room"), "room_id": .string(id)], expectedRoomID: id, activates: activates || roomID == nil)
    }

    private func readRoom(_ body: [String: JSONValue], expectedRoomID: String?, activates: Bool) async throws -> GameRoom? {
        let generation = roomEpoch
        let actor = userID
        let membership = room?.viewerMembershipID
        do {
            let response = try await read(body)
            guard actor == userID, generation == roomEpoch, room?.viewerMembershipID == membership else { throw Self.staleContext }
            guard response.object?.keys.contains("room") == true else { throw Self.invalidResponse }
            if response["room"].isNull {
                clearRoom(expectedRoomID: expectedRoomID, generation: generation, membership: membership)
                return nil
            }
            let candidate = try Self.decodeRoom(response["room"])
            if let expectedRoomID, body["action"]?.string == "get_room", candidate.id != expectedRoomID { throw Self.invalidResponse }
            if activates || roomID == nil || roomID == candidate.id { try adopt(response["room"], activates: activates) }
            lastError = ""
            return roomID == candidate.id ? room : candidate
        } catch {
            let failure = Self.failure(error).error
            if actor == userID, generation == roomEpoch,
               Self.isMembershipLoss(failure) {
                clearRoom(expectedRoomID: expectedRoomID, generation: generation, membership: membership)
                return nil
            }
            throw failure
        }
    }

    @discardableResult
    func command(_ input: [String: JSONValue]) async throws -> JSONValue {
        guard transport != nil, !userID.isEmpty else { throw Self.notSignedIn }
        guard !commandInFlight else { throw Self.recoveryRequired }
        let source = JSONValue.object(input)
        if let pending {
            guard pending.actorID == userID, pending.source == source else { throw Self.recoveryRequired }
            return try await retryPendingResponse()
        }
        var body = input
        let requestID = input["request_id"]?.string ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: requestID) != nil, let action = body["action"]?.string else { throw Self.invalidResponse }
        body["request_id"] = .string(requestID)
        if let current = room, body["room_id"]?.string == current.id {
            if body["expected_membership_id"] == nil, let membership = current.viewerMembershipID {
                body["expected_membership_id"] = .string(membership)
            }
            if body["expected_match_id"] == nil, let match = current.matchID {
                body["expected_match_id"] = .string(match)
            }
            if action == "arm_roulette", body["expected_lobby_revision"] == nil, let revision = current.lobbyRevision {
                body["expected_lobby_revision"] = .number(Double(revision))
            }
            if Self.turnActions.contains(action), body["expected_revision"] == nil, let revision = current.roomRevision {
                body["expected_revision"] = .number(Double(revision))
            }
        }
        pending = Intent(requestID: requestID, actorID: userID, source: source, body: .object(body))
        do { try persistJournal() }
        catch { pending = nil; throw error }
        return try await retryPendingResponse()
    }

    @discardableResult
    func retryPending() async throws -> GameRoom? {
        if pending != nil { _ = try await retryPendingResponse() }
        else if let roomID { _ = try await refreshRoom(id: roomID) }
        return room
    }

    func retryPendingResponse() async throws -> JSONValue {
        guard let transport, let intent = pending, intent.actorID == userID else { throw Self.notSignedIn }
        guard !commandInFlight else { throw Self.recoveryRequired }
        let commandEpoch = transportEpoch
        let commandActor = userID
        commandInFlight = true
        defer { if commandEpoch == transportEpoch, commandActor == userID { commandInFlight = false } }
        let response: JSONValue
        if let acknowledgement = intent.acknowledgement {
            // A known commit is resolved by an authoritative read, never by
            // resending or repeatedly decoding a stale/malformed projection.
            response = try await recoverAcknowledgement(acknowledgement, intent: intent)
        } else {
            do { response = try await transport.fullGame(intent.body) }
            catch {
                guard commandEpoch == transportEpoch, commandActor == userID else { throw CancellationError() }
                let failure = Self.failure(error)
                if !failure.ambiguous { pending = nil; try? persistJournal() }
                lastError = failure.error.code ?? "request_failed"
                persistEvidence()
                throw failure.error
            }
            guard commandEpoch == transportEpoch, commandActor == userID,
                  pending?.requestID == intent.requestID else { throw CancellationError() }
            // A valid receipt identifies a known commit. An invalid envelope
            // remains an unknown outcome and is retried with the original ID.
            guard response["receipt"]["request_id"].string == intent.requestID else { throw Self.invalidResponse }
            pending?.acknowledgement = response
            try persistJournal()
            lastReceipt = response["receipt"]
            let action = intent.body["action"].string ?? ""
            let target = response["receipt"]["room_id"].string ?? intent.body["room_id"].string
            if ["leave_room", "close_room"].contains(action), let target {
                _ = try await refreshRoom(id: target)
            } else if !response["room"].isNull {
                let candidate = try Self.decodeRoom(response["room"])
                guard candidate.id == target, (candidate.roomRevision ?? 0) >= response["receipt"]["revision"].integer else { throw Self.invalidResponse }
                try adopt(response["room"], activates: ["create_room", "join_room"].contains(action))
            } else if let target, !Self.packActions.contains(action) {
                let current = try await refreshRoom(id: target)
                if let current, (current.roomRevision ?? 0) < response["receipt"]["revision"].integer { throw Self.invalidResponse }
            } else if Self.packActions.contains(action) {
                try Self.validatePackResponse(response, action: action)
            } else { throw Self.invalidResponse }
        }
        guard commandEpoch == transportEpoch, commandActor == userID,
              pending?.requestID == intent.requestID else { throw CancellationError() }
        pending = nil
        lastError = ""
        try persistJournal()
        persistEvidence()
        return response
    }

    private func recoverAcknowledgement(_ response: JSONValue, intent: Intent) async throws -> JSONValue {
        guard response["receipt"]["request_id"].string == intent.requestID else { throw Self.invalidResponse }
        lastReceipt = response["receipt"]
        let action = intent.body["action"].string ?? ""
        if Self.packActions.contains(action) {
            try Self.validatePackResponse(response, action: action)
            return response
        }
        guard let target = response["receipt"]["room_id"].string ?? intent.body["room_id"].string else { throw Self.invalidResponse }
        let current = try await refreshRoom(id: target, activates: ["create_room", "join_room"].contains(action))
        if let current, (current.roomRevision ?? 0) < response["receipt"]["revision"].integer { throw Self.invalidResponse }
        var latest = response.object ?? [:]
        latest["room"] = try current.map(Self.json) ?? .null
        return .object(latest)
    }

    private static func validatePackResponse(_ response: JSONValue, action: String) throws {
        if action == "delete_word_pack" { return }
        guard (try? JSONDecoder().decode(WordPack.self, from: response["pack"].data())) != nil else { throw invalidResponse }
    }

    /// Accept only the current room generation and monotonically newer revisions.
    func adopt(_ value: JSONValue, activates: Bool = false) throws {
        let candidate = try Self.decodeRoom(value)
        guard roomID == nil || roomID == candidate.id || activates else { return }
        if let room, room.id == candidate.id, (room.roomRevision ?? 0) > (candidate.roomRevision ?? 0) { return }
        if roomID != candidate.id { roomEpoch += 1; stopWatch() }
        roomID = candidate.id
        snapshot = value
        room = candidate
        try? persistJournal()
        persistEvidence()
        scheduleWatch()
    }

    func clearRoom(expectedRoomID: String?, generation: Int, membership: String?) {
        guard generation == roomEpoch,
              expectedRoomID == nil || roomID == expectedRoomID,
              room?.viewerMembershipID == membership else { return }
        roomEpoch += 1
        stopWatch()
        roomID = nil; room = nil; snapshot = .null
        try? persistJournal()
        persistEvidence()
    }

    private func scheduleWatch() {
        guard automaticallyWatches, let transport, let target = roomID, watchTask == nil,
              watchedRoomID != target || realtime != "subscribed" else { return }
        let generation = roomEpoch
        let connection = transportEpoch
        watchedRoomID = target
        watchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.transportEpoch == connection, self.roomEpoch == generation { self.watchTask = nil }
            }
            do {
                try Task.checkCancellation()
                try await transport.watch(roomID: target, table: "full_game_room_signals")
                try Task.checkCancellation()
                guard self.transportEpoch == connection, self.roomEpoch == generation, self.roomID == target else { return }
                self.realtime = "subscribed"
                await self.reconcile()
            } catch {
                guard self.transportEpoch == connection, self.roomEpoch == generation else { return }
                self.realtime = "disconnected"
            }
        }
    }

    private func stopWatch() {
        watchTask?.cancel(); watchTask = nil
        transport?.disconnectRealtime()
        watchedRoomID = nil; realtime = "disconnected"
    }

    private func reconcile() async {
        guard !refreshInFlight, let roomID else { return }
        let epoch = roomEpoch
        let connection = transportEpoch
        refreshInFlight = true
        defer { if connection == transportEpoch { refreshInFlight = false } }
        do { _ = try await refreshRoom(id: roomID); scheduleWatch() }
        catch {
            guard epoch == roomEpoch else { return }
            lastError = Self.failure(error).error.code ?? "refresh_failed"
        }
        guard epoch == roomEpoch else { return }
        persistEvidence()
    }

    private func restoreJournal() {
        guard let data = try? Data(contentsOf: journalURL),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data), saved.actorID == userID else { return }
        pending = saved.pending?.actorID == userID ? saved.pending : nil
        // A cached role is never displayed before an authorized current read.
        roomID = saved.roomID
    }

    private var accountDirectory: URL {
#if SPYCLASH_SUPABASE
        evidenceDirectory.appendingPathComponent(userID.isEmpty ? "signed-out" : userID, isDirectory: true)
#else
        evidenceDirectory
#endif
    }
    private var journalURL: URL { accountDirectory.appendingPathComponent("journal.json") }
    private func persistJournal() throws {
        do {
            try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
            let state = SavedState(actorID: userID, roomID: roomID, snapshot: snapshot, pending: pending)
            try JSONEncoder().encode(state).write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            throw Base44Error(message: "The saved action could not be stored. Retry when device storage is available.", code: "local_durability_failure", retryable: true)
        }
    }

    private func persistEvidence() {
        let value: JSONValue = .object([
            "protocol": .string("full_game_core"), "user_id": .string(userID),
            "build": .number(Double(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0),
            "room_id": roomID.map(JSONValue.string) ?? .null, "snapshot": snapshot,
            "revision": snapshot["room_revision"], "status": .string(phase),
            "pending_ids": .array(pendingIDs.map(JSONValue.string)), "last_receipt": lastReceipt,
            "realtime": .string(realtime), "last_error": .string(lastError)
        ])
        try? value.data().write(to: accountDirectory.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func decodeRoom(_ value: JSONValue) throws -> GameRoom {
        guard !value.isNull, let room = try? JSONDecoder().decode(GameRoom.self, from: value.data()),
              room.roomRevision != nil, !room.id.isEmpty else { throw invalidResponse }
        return room
    }
    static func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
    static func failure(_ error: Error) -> FullGameTransportFailure {
        if let failure = error as? FullGameTransportFailure { return failure }
        if let error = error as? Base44Error { return FullGameTransportFailure(error: error, ambiguous: false) }
        let lab = safeFailure(error)
        return FullGameTransportFailure(error: Base44Error(message: "Connection interrupted. Your saved action can be retried.", statusCode: 503, code: lab.code, retryable: true), ambiguous: lab.ambiguous)
    }
    private static func isMembershipLoss(_ error: Base44Error) -> Bool {
        ["not_member", "room_not_found", "room_access_revoked", "room_departed"].contains(error.code ?? "") || error.statusCode == 404
    }
    private static let turnActions: Set<String> = ["advance_question", "advance_association", "start_association", "stop_association_spin", "mark_answer_heard", "continue_round"]
    private static let packActions: Set<String> = ["create_word_pack", "update_word_pack", "delete_word_pack"]
    static var recoveryRequired: Base44Error { Base44Error(message: "A saved action is still unresolved. Retry it before another action.", statusCode: 409, code: "pending_command_requires_retry") }
    static var notSignedIn: Base44Error { Base44Error(message: "Test account is not signed in.", statusCode: 401, code: "not_signed_in") }
    static var invalidResponse: Base44Error { Base44Error(message: "The server response could not be confirmed. Retry the saved action.", statusCode: 502, code: "invalid_full_game_response", retryable: true) }
    static var staleContext: Base44Error { Base44Error(message: "Room context changed.", statusCode: 409, code: "stale_room_context") }
}
#endif
