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
    private struct CommandTask {
        let id: UUID
        let source: JSONValue
        let task: Task<JSONValue, Error>
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
    /// Ordinary requests are invisible to recovery UI; only an unresolved
    /// failure (or a restored journal) enters this state.
    private(set) var isRecoveringSavedCommand = false
    private(set) var recoveryGeneration = 0
    private(set) var recoveredResponse: JSONValue = .null
    private(set) var recoveredAction: String?
    @ObservationIgnored private var transport: (any SupabaseFullGameTransport)?
    @ObservationIgnored private let evidenceDirectory: URL
    @ObservationIgnored private let automaticallyWatches: Bool
    @ObservationIgnored private let automaticallyRecovers: Bool
    @ObservationIgnored private let recoverySleep: (Duration) async throws -> Void
    @ObservationIgnored private let recoveryNow: () -> ContinuousClock.Instant
    @ObservationIgnored private var recoveryNotBefore: ContinuousClock.Instant?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryWorkerID: UUID?
    @ObservationIgnored private var activeCommandTask: Task<JSONValue, Error>?
    @ObservationIgnored private var activeCommandID: String?
    @ObservationIgnored private var foregroundConsumers: [String: Int] = [:]
    @ObservationIgnored private var commandTasks: [CommandTask] = []
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

    init(transport: (any SupabaseFullGameTransport)? = nil, actorID: String = "", name: String = "Player", evidenceDirectory: URL? = nil, automaticallyWatches: Bool = true, automaticallyRecovers: Bool = true,
         recoverySleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         recoveryNow: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.automaticallyWatches = automaticallyWatches
        self.automaticallyRecovers = automaticallyRecovers
        self.recoverySleep = recoverySleep
        self.recoveryNow = recoveryNow
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
        recoveryTask?.cancel(); recoveryTask = nil; recoveryWorkerID = nil
        activeCommandTask?.cancel(); activeCommandTask = nil; activeCommandID = nil
        foregroundConsumers = [:]
        commandTasks.forEach { $0.task.cancel() }; commandTasks = []
        stopWatch()
        transport = nil; userID = ""; name = "Player"
        room = nil; roomID = nil; snapshot = .null; pending = nil
        lastError = ""; lastReceipt = .null; signalRevisions = []
        commandInFlight = false; refreshInFlight = false
        isRecoveringSavedCommand = false; recoveryNotBefore = nil
        recoveredResponse = .null; recoveredAction = nil
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
        resumePendingRecovery()
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
        let connection = transportEpoch
        let actor = userID
        let membership = room?.viewerMembershipID
        do {
            let response = try await read(body)
            guard connection == transportEpoch, actor == userID, generation == roomEpoch,
                  room?.viewerMembershipID == membership else { throw Self.staleContext }
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
            if connection == transportEpoch, actor == userID, generation == roomEpoch,
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
        let source = JSONValue.object(input)
        if let existing = commandTasks.first(where: { $0.source == source }) { return try await existing.task.value }
        if let pending, pending.actorID == userID, pending.source == source {
            // Repeated taps observe the same operation, including its original
            // request ID and all its original optimistic-concurrency fences.
            return try await retryPendingResponse()
        }
        let connection = transportEpoch
        let actor = userID
        let generation = roomEpoch
        let membership = room?.viewerMembershipID
        let match = room?.matchID
        let revision = room?.roomRevision
        let lobbyRevision = room?.lobbyRevision
        // Bind this new intent before awaiting a preceding command. A queued
        // tap must never silently become an action in a different match/turn.
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
        let queuedID = UUID()
        let intent = Intent(requestID: requestID, actorID: actor, source: source, body: .object(body))
        let task = Task { [weak self] () async throws -> JSONValue in
            guard let self else { throw CancellationError() }
            defer { self.commandTasks.removeAll { $0.id == queuedID } }
            try Task.checkCancellation()
            guard connection == self.transportEpoch, actor == self.userID else { throw CancellationError() }
            return try await self.sendNewIntent(intent, connection: connection, generation: generation,
                                                membership: membership, match: match, revision: revision, lobbyRevision: lobbyRevision)
        }
        commandTasks.append(CommandTask(id: queuedID, source: source, task: task))
        return try await task.value
    }

    private func sendNewIntent(_ intent: Intent, connection: Int, generation: Int, membership: String?, match: String?, revision: Int?, lobbyRevision: Int?) async throws -> JSONValue {
        let action = intent.body["action"].string ?? ""
        // A different intent may follow an ordinary in-flight action or a
        // successful recovery, but is never sent beside an unresolved write.
        while pending != nil {
            if pending?.source == intent.source { return try await retryPendingResponse() }
            do { _ = try await pendingResponse(consumesResponse: false) }
            catch {
                guard connection == transportEpoch, intent.actorID == userID else { throw CancellationError() }
                if pending != nil { throw Self.recoveryRequired }
                throw error
            }
            guard connection == transportEpoch, intent.actorID == userID else { throw CancellationError() }
            guard generation == roomEpoch, membership == room?.viewerMembershipID, match == room?.matchID else { throw Self.staleContext }
            if Self.turnActions.contains(action), let expected = intent.body.object?["expected_revision"], expected != snapshot["room_revision"] {
                throw Self.staleContext
            }
            if action == "arm_roulette", let expected = intent.body.object?["expected_lobby_revision"], expected != snapshot["lobby_revision"] {
                throw Self.staleContext
            }
        }
        guard connection == transportEpoch, intent.actorID == userID else { throw CancellationError() }
        guard generation == roomEpoch, membership == room?.viewerMembershipID, match == room?.matchID else { throw Self.staleContext }
        if Self.turnActions.contains(action), revision != room?.roomRevision { throw Self.staleContext }
        if action == "arm_roulette", lobbyRevision != room?.lobbyRevision { throw Self.staleContext }
        pending = intent
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
        try await pendingResponse(consumesResponse: true)
    }

    /// Called on foreground entry, reconnection and normal reconciliation.
    /// Recovery replays only the journaled request; it never builds a new one.
    func resumePendingRecovery() {
        scheduleAutomaticRecovery(immediate: true)
    }

    private func pendingResponse(consumesResponse: Bool) async throws -> JSONValue {
        guard let intent = pending, intent.actorID == userID, transport != nil else { throw Self.notSignedIn }
        let connection = transportEpoch
        if consumesResponse { foregroundConsumers[intent.requestID, default: 0] += 1 }
        defer {
            if consumesResponse, connection == transportEpoch {
                foregroundConsumers[intent.requestID, default: 1] -= 1
                if foregroundConsumers[intent.requestID] == 0 { foregroundConsumers[intent.requestID] = nil }
            }
        }
        if let activeCommandTask, activeCommandID == intent.requestID { return try await activeCommandTask.value }
        commandInFlight = true
        activeCommandID = intent.requestID
        let task = Task { [weak self] () async throws -> JSONValue in
            guard let self else { throw CancellationError() }
            defer {
                if connection == self.transportEpoch, self.activeCommandID == intent.requestID {
                    self.activeCommandTask = nil; self.activeCommandID = nil
                    self.commandInFlight = false
                }
            }
            do { return try await self.sendPending(intent, connection: connection) }
            catch {
                guard connection == self.transportEpoch, intent.actorID == self.userID else { throw CancellationError() }
                if self.pending?.requestID == intent.requestID {
                    self.isRecoveringSavedCommand = true
                    self.lastError = Self.failure(error).error.code ?? "request_failed"
                    self.scheduleAutomaticRecovery(immediate: false)
                }
                self.persistEvidence()
                throw error
            }
        }
        activeCommandTask = task
        return try await task.value
    }

    private func sendPending(_ intent: Intent, connection: Int) async throws -> JSONValue {
        guard let transport else { throw Self.notSignedIn }
        if isRecoveringSavedCommand, let deadline = recoveryNotBefore, deadline > recoveryNow() {
            try await recoverySleep(recoveryNow().duration(to: deadline))
            try Task.checkCancellation()
            guard connection == transportEpoch, intent.actorID == userID,
                  pending?.requestID == intent.requestID else { throw CancellationError() }
        }
        let generation = roomEpoch
        let membership = room?.viewerMembershipID
        let isReplay = isRecoveringSavedCommand
        let response: JSONValue
        if let acknowledgement = intent.acknowledgement {
            // A known commit is resolved by an authoritative read, never by
            // resending or repeatedly decoding a stale/malformed projection.
            response = try await recoverAcknowledgement(acknowledgement, intent: intent)
        } else {
            let received: JSONValue
            do { received = try await transport.fullGame(intent.body) }
            catch {
                guard connection == transportEpoch, intent.actorID == userID else { throw CancellationError() }
                let failure = Self.failure(error)
                if failure.ambiguous, let seconds = failure.error.retryAfterSeconds, seconds > 0 {
                    recoveryNotBefore = recoveryNow().advanced(by: .seconds(seconds))
                }
                if !failure.ambiguous {
                    pending = nil
                    do { try persistJournal() }
                    catch { pending = intent; throw error }
                    isRecoveringSavedCommand = false
                    stopAutomaticRecovery()
                }
                lastError = failure.error.code ?? "request_failed"
                throw failure.error
            }
            guard connection == transportEpoch, intent.actorID == userID,
                  pending?.requestID == intent.requestID else { throw CancellationError() }
            guard received["receipt"]["request_id"].string == intent.requestID else { throw Self.invalidResponse }
            pending?.acknowledgement = received
            try persistJournal()
            lastReceipt = received["receipt"]
            let action = intent.body["action"].string ?? ""
            let target = received["receipt"]["room_id"].string ?? intent.body["room_id"].string
            if isReplay || generation != roomEpoch || membership != room?.viewerMembershipID {
                // A replayed receipt may contain a former membership/role even
                // after leaving or being kicked. Re-authorize it with a read.
                response = try await recoverAcknowledgement(received, intent: intent,
                                                            activates: generation == roomEpoch && membership == room?.viewerMembershipID)
            } else if ["leave_room", "close_room"].contains(action), let target {
                _ = try await refreshRoom(id: target)
                response = received
            } else if !received["room"].isNull {
                let candidate = try Self.decodeRoom(received["room"])
                guard candidate.id == target, (candidate.roomRevision ?? 0) >= received["receipt"]["revision"].integer else { throw Self.invalidResponse }
                if candidate.id == roomID, let currentMembership = room?.viewerMembershipID,
                   candidate.viewerMembershipID != currentMembership {
                    response = try await recoverAcknowledgement(received, intent: intent, activates: false)
                } else {
                    try adopt(received["room"], activates: ["create_room", "join_room"].contains(action))
                    response = received
                }
            } else if let target, !Self.packActions.contains(action) {
                let current = try await refreshRoom(id: target)
                if let current, (current.roomRevision ?? 0) < received["receipt"]["revision"].integer { throw Self.invalidResponse }
                response = received
            } else if Self.packActions.contains(action) {
                try Self.validatePackResponse(received, action: action)
                response = received
            } else { throw Self.invalidResponse }
        }
        guard connection == transportEpoch, intent.actorID == userID,
              pending?.requestID == intent.requestID else { throw CancellationError() }
        let wasRecovering = isRecoveringSavedCommand
        let committed = pending
        pending = nil
        do { try persistJournal() }
        catch { pending = committed; throw error }
        isRecoveringSavedCommand = false
        stopAutomaticRecovery()
        lastError = ""
        if wasRecovering, foregroundConsumers[intent.requestID, default: 0] == 0 {
            recoveredResponse = response
            recoveredAction = intent.body["action"].string
            recoveryGeneration += 1
        }
        persistEvidence()
        return response
    }

    private func stopAutomaticRecovery() {
        recoveryTask?.cancel(); recoveryTask = nil; recoveryWorkerID = nil
        recoveryNotBefore = nil
    }

    private func scheduleAutomaticRecovery(immediate: Bool) {
        guard automaticallyRecovers, isRecoveringSavedCommand, let intent = pending,
              intent.actorID == userID, transport != nil, recoveryTask == nil else { return }
        let connection = transportEpoch
        let workerID = UUID()
        let sleep = recoverySleep
        recoveryWorkerID = workerID
        // Each wake has a bounded retry burst; normal reconciliation will
        // resume a later burst during a longer outage without busy-looping.
        let delays: [Duration] = immediate ? [.zero, .seconds(1), .seconds(2), .seconds(4)]
                                           : [.milliseconds(400), .seconds(1), .seconds(2), .seconds(4)]
        recoveryTask = Task { [weak self] in
            defer {
                if let self, self.recoveryWorkerID == workerID {
                    self.recoveryTask = nil; self.recoveryWorkerID = nil
                }
            }
            for baseDelay in delays {
                var delay = baseDelay
                if let self, let deadline = self.recoveryNotBefore {
                    delay = max(delay, self.recoveryNow().duration(to: deadline))
                }
                do {
                    if delay > .zero { try await sleep(delay) }
                    try Task.checkCancellation()
                } catch { return }
                guard let self, self.transportEpoch == connection,
                      self.userID == intent.actorID, self.pending?.requestID == intent.requestID else { return }
                do { _ = try await self.pendingResponse(consumesResponse: false); return }
                catch {
                    guard self.transportEpoch == connection, self.pending?.requestID == intent.requestID else { return }
                }
            }
        }
    }

    private func recoverAcknowledgement(_ response: JSONValue, intent: Intent, activates: Bool = true) async throws -> JSONValue {
        guard response["receipt"]["request_id"].string == intent.requestID else { throw Self.invalidResponse }
        lastReceipt = response["receipt"]
        let action = intent.body["action"].string ?? ""
        if Self.packActions.contains(action) {
            if (try? Self.validatePackResponse(response, action: action)) != nil { return response }
            guard let packID = response["pack"]["id"].string ?? intent.body["pack_id"].string else { throw Self.invalidResponse }
            let fresh = try await read(["action": .string("get_word_pack"), "pack_id": .string(packID)])
            try Self.validatePackResponse(fresh, action: action)
            var latest = response.object ?? [:]
            latest["pack"] = fresh["pack"]
            return .object(latest)
        }
        guard let target = response["receipt"]["room_id"].string ?? intent.body["room_id"].string else { throw Self.invalidResponse }
        let current = try await refreshRoom(id: target, activates: activates && ["create_room", "join_room"].contains(action))
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
        resumePendingRecovery()
        guard !refreshInFlight, let roomID else { return }
        let epoch = roomEpoch
        let connection = transportEpoch
        refreshInFlight = true
        defer { if connection == transportEpoch { refreshInFlight = false } }
        do { _ = try await refreshRoom(id: roomID); scheduleWatch() }
        catch {
            guard connection == transportEpoch, epoch == roomEpoch else { return }
            lastError = Self.failure(error).error.code ?? "refresh_failed"
        }
        guard connection == transportEpoch, epoch == roomEpoch else { return }
        persistEvidence()
    }

    private func restoreJournal() {
        guard let data = try? Data(contentsOf: journalURL),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data), saved.actorID == userID else { return }
        pending = saved.pending?.actorID == userID ? saved.pending : nil
        isRecoveringSavedCommand = pending != nil
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
        if let failure = error as? FullGameTransportFailure {
            return FullGameTransportFailure(error: failure.error, ambiguous: failure.ambiguous || isTransient(failure.error))
        }
        if let error = error as? Base44Error { return FullGameTransportFailure(error: error, ambiguous: isTransient(error)) }
        let lab = safeFailure(error)
        return FullGameTransportFailure(error: Base44Error(message: "Connection interrupted. Reconnecting automatically.", statusCode: 503, code: lab.code, retryable: true), ambiguous: lab.ambiguous)
    }
    private static func isTransient(_ error: Base44Error) -> Bool {
        error.retryable || [401, 408, 425, 429].contains(error.statusCode ?? 0) || (error.statusCode ?? 0) >= 500
    }
    private static func isMembershipLoss(_ error: Base44Error) -> Bool {
        ["not_member", "room_not_found", "room_access_revoked", "room_departed"].contains(error.code ?? "") || error.statusCode == 404
    }
    private static let turnActions: Set<String> = ["advance_question", "advance_association", "start_association", "stop_association_spin", "mark_answer_heard", "continue_round"]
    private static let packActions: Set<String> = ["create_word_pack", "update_word_pack", "delete_word_pack"]
    static var recoveryRequired: Base44Error { Base44Error(message: "Synchronizing your previous action. Please wait a moment.", statusCode: 409, code: "pending_command_requires_retry") }
    static var notSignedIn: Base44Error { Base44Error(message: "Test account is not signed in.", statusCode: 401, code: "not_signed_in") }
    static var invalidResponse: Base44Error { Base44Error(message: "The server response could not be confirmed. Synchronizing automatically.", statusCode: 502, code: "invalid_full_game_response", retryable: true) }
    static var staleContext: Base44Error { Base44Error(message: "Room context changed.", statusCode: 409, code: "stale_room_context") }
}
#endif
