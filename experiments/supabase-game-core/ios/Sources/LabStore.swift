import Foundation
import Observation

@MainActor @Observable
final class LabStore {
    var name = "Player"
    var userID = ""
    var backendLabel = "No test backend configured"
    var roomEntry = ""
    var roomID: String?
    var snapshot: JSONValue = .null
    var realtime = "disconnected"
    var signalRevisions: [Int] = []
    var lastError = ""
    var status = "Configure a synthetic test account"
    var busy = false
    var roleRevealed = false
    var pending: [String: Intent] = [:]
    var lastReceipt: JSONValue = .null

    struct Intent: Codable, Equatable {
        let requestID: String
        let actorID: String
        let roomID: String
        let action: String
        let source: JSONValue
        let body: JSONValue
    }

    @ObservationIgnored private var backend: BackendClient?
    @ObservationIgnored private var snapshots: [String: JSONValue] = [:]
    @ObservationIgnored private var intents: [String: Intent] = [:]
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var controlTask: Task<Void, Never>?
    @ObservationIgnored private var watchingRoom: String?
    @ObservationIgnored private var realtimePaused = false
    @ObservationIgnored private var watchInFlight = false
    @ObservationIgnored private var refreshInFlight = false
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var controller: NativeController?
    @ObservationIgnored private var clientID = "manual"
    @ObservationIgnored private var eventSequence = 0
    @ObservationIgnored private var roomEpoch = 0

    var players: [JSONValue] { snapshot["players"].array }
    var phase: String { snapshot["phase"].string ?? "idle" }
    var isHost: Bool { snapshot["host_id"].string == userID && !userID.isEmpty }
    var pendingIDs: [String] { pending.keys.sorted() }
    var roomContextGeneration: Int { roomEpoch }
    var watchedRoomID: String? { watchingRoom }
    var ownReady: Bool { players.first(where: { $0["user_id"].string == userID })?["ready"].bool ?? false }

    func bootstrap() async {
        guard !bootstrapped else { return }; bootstrapped = true
        let env = ProcessInfo.processInfo.environment
        do {
            if let raw = env["LAB_CONTROL_URL"], let token = env["LAB_CONTROL_TOKEN"], let id = env["LAB_CLIENT_ID"] {
                let controller = try NativeController(base: raw, token: token, clientID: id)
                self.controller = controller; clientID = id
                status = "Connecting to the local test controller"
                var configuration: LabConfiguration?
                for attempt in 0..<30 {
                    do { configuration = try await controller.configuration(); break }
                    catch { if attempt == 29 { throw error }; try await Task.sleep(for: .seconds(1)) }
                }
                guard let configuration else { throw LabFailure(code: "controller_configuration_missing") }
                try await connect(configuration)
                await emit("boot", result: state)
                controlTask = Task { [weak self] in await self?.pollController() }
            } else if let path = env["LAB_CONFIG_PATH"] {
                let configuration = try JSONDecoder().decode(LabConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                try await connect(configuration)
            } else if let url = env["LAB_BACKEND_URL"], let key = env["LAB_PUBLISHABLE_KEY"],
                      let email = env["LAB_EMAIL"], let password = env["LAB_PASSWORD"] {
                try await connect(LabConfiguration(backendURL: url, publishableKey: key, email: email,
                    password: password, name: env["LAB_NAME"] ?? "Native player", transportURL: env["LAB_TRANSPORT_URL"]))
            }
        } catch { record(error) }
    }

    func connect(_ configuration: LabConfiguration) async throws {
        let client = try BackendClient(config: configuration)
        status = "Signing in to the test backend"
        try await client.signIn()
        backend?.disconnectRealtime()
        backend = client; name = configuration.name; userID = client.userID
        backendLabel = URL(string: configuration.backendURL)?.host ?? "Test backend"
        status = "Signed in · synthetic test account"; lastError = ""
        restorePending()
        client.onRealtime = { [weak self] event, value in
            guard let self else { return }
            if event == "signal" {
                if let value, value["room_id"].string == self.watchingRoom {
                    self.signalRevisions.append(value["revision"].integer)
                    self.signalRevisions = Array(self.signalRevisions.suffix(100))
                    Task { await self.reconcile(reason: "signal") }
                }
            } else { self.realtime = event }
            self.persistState()
            Task { await self.emit("realtime", result: .object(["status": .string(event)])) }
        }
        startReconciliation()
        persistState()
    }

    func performUI(_ action: String, payload: [String: JSONValue] = [:], room: String? = nil) {
        guard !busy else { return }
        busy = true; lastError = ""
        Task {
            defer { busy = false }
            do {
                let target = room ?? roomID ?? roomEntry
                _ = try await command(room: target, action: action, payload: .object(payload))
            } catch { record(error) }
        }
    }

    func createRoom() { performUI("create_room", payload: ["name": .string(name), "settings": .object(["max_players": .number(6)])], room: UUID().uuidString.lowercased()) }
    func joinRoom() { performUI("join_room", payload: ["name": .string(name)], room: roomEntry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }

    func command(room: String, action: String, payload: JSONValue = .object([:]), requestID: String? = nil) async throws -> JSONValue {
        guard let backend, !userID.isEmpty else { throw LabFailure(code: "not_signed_in") }
        guard UUID(uuidString: room) != nil, var bound = payload.object else { throw LabFailure(code: "invalid_command") }
        let id = (requestID ?? UUID().uuidString).lowercased()
        guard UUID(uuidString: id) != nil else { throw LabFailure(code: "invalid_request_id") }
        let source: JSONValue = .object(["room_id": .string(room), "action": .string(action), "payload": payload])
        let intent: Intent
        if let existing = intents[id] {
            guard existing.source == source else { throw LabFailure(code: "idempotency_mismatch") }
            intent = existing
        } else {
            if !["create_room", "join_room"].contains(action) {
                // Capture generations exactly once from the state the actor saw.
                // Replay never refreshes or rewrites this bound payload.
                let context: JSONValue
                if let current = snapshots[room] { context = current }
                else { context = try await refresh(room: room) }
                if ["set_ready", "leave_room"].contains(action), bound["membership_id"] == nil { bound["membership_id"] = context["own_membership_id"] }
                if action == "set_ready", bound["settings_revision"] == nil { bound["settings_revision"] = context["settings_revision"] }
                if action == "start_game" || (action == "close_room" && context["phase"].string == "lobby") {
                    if bound["lobby_id"] == nil { bound["lobby_id"] = context["lobby_id"] }
                }
                if action == "update_settings", bound["expected_revision"] == nil { bound["expected_revision"] = context["revision"] }
                if ["open_voting", "vote", "return_to_lobby", "leave_room", "close_room"].contains(action),
                   !context["match_id"].isNull, bound["match_id"] == nil { bound["match_id"] = context["match_id"] }
            }
            let body: JSONValue = .object(["p_request_id": .string(id), "p_room_id": .string(room),
                "p_action": .string(action), "p_payload": .object(bound)])
            intent = Intent(requestID: id, actorID: backend.userID, roomID: room, action: action, source: source, body: body)
            intents[id] = intent
        }
        pending[id] = intent; persistPending(); persistState()
        return try await retry(requestID: id)
    }

    func retry(requestID: String) async throws -> JSONValue {
        guard let backend, let intent = pending[requestID.lowercased()], intent.actorID == userID else {
            throw LabFailure(code: "pending_command_not_found")
        }
        let result: JSONValue
        do { result = try await backend.rpc("game_command", body: intent.body) }
        catch {
            let failure = safeFailure(error)
            if !failure.ambiguous { pending.removeValue(forKey: intent.requestID); persistPending() }
            record(failure); throw failure
        }
        pending.removeValue(forKey: intent.requestID); persistPending()
        lastReceipt = result; lastError = ""; status = "Committed \(intent.action) · revision \(result["revision"].integer)"
        if intent.action == "leave_room" {
            // A replayed historical leave receipt must not clear a newer rejoin.
            // Only current server membership, never the old receipt, decides.
            do { _ = try await refresh(room: intent.roomID) }
            catch {
                let failure = safeFailure(error)
                if failure.code == "not_member" {
                    if roomID == intent.roomID {
                        roomEpoch += 1
                        stopWatch(); roomID = nil; snapshot = .null; roleRevealed = false
                    }
                    lastError = ""
                } else { lastError = failure.code }
            }
        } else {
            if roomID != intent.roomID { roomEpoch += 1; snapshot = .null }
            roomID = intent.roomID; roomEntry = intent.roomID
            // Read failures after a known commit must not turn its receipt into an error.
            var membershipConfirmed = false
            do { _ = try await refresh(room: intent.roomID); membershipConfirmed = true }
            catch {
                let failure = safeFailure(error)
                if failure.code == "not_member", roomID == intent.roomID {
                    roomEpoch += 1
                    stopWatch(); roomID = nil; snapshot = .null; roleRevealed = false
                } else { lastError = failure.code }
            }
            if membershipConfirmed, ["create_room", "join_room"].contains(intent.action) {
                do { try await watch(room: intent.roomID) }
                catch { lastError = safeFailure(error).code }
            }
        }
        persistState()
        return result
    }

    @discardableResult
    func refresh(room: String, activate: Bool = false) async throws -> JSONValue {
        guard let backend, UUID(uuidString: room) != nil else { throw LabFailure(code: "invalid_room") }
        let epoch = roomEpoch
        let membership = snapshot["own_membership_id"].string
        let result: JSONValue
        do { result = try await backend.rpc("game_snapshot", body: .object(["p_room_id": .string(room)])) }
        catch {
            let failure = safeFailure(error)
            if ["not_member", "room_not_found"].contains(failure.code) {
                guard epoch == roomEpoch,
                      roomID != room || snapshot["own_membership_id"].string == membership else {
                    throw LabFailure(code: "stale_room_context", ambiguous: true)
                }
                clearCurrentRoomAfterMembershipLoss(roomID: room, expectedGeneration: epoch, expectedMembershipID: membership)
            }
            throw error
        }
        // A read begun before leave/switch cannot re-open the old room in UI.
        guard epoch == roomEpoch else { throw LabFailure(code: "stale_room_context", ambiguous: true) }
        if let prior = snapshots[room], result["revision"].integer < prior["revision"].integer { return prior }
        snapshots[room] = result
        if roomID == nil || roomID == room || (activate && result["phase"].string != "closed") {
            if roomID != room { roomEpoch += 1 }
            if snapshot["match_id"] != result["match_id"] { roleRevealed = false }
            roomID = room; snapshot = result; roomEntry = room
        }
        lastError = ""
        persistState()
        return result
    }

    /// Definitive authorization loss invalidates the old read generation. A
    /// delayed failure from before a rejoin cannot evict its newer membership.
    func clearCurrentRoomAfterMembershipLoss(roomID room: String, expectedGeneration: Int, expectedMembershipID: String?) {
        guard roomID == room, roomEpoch == expectedGeneration,
              snapshot["own_membership_id"].string == expectedMembershipID else { return }
        roomEpoch += 1
        stopWatch()
        snapshots.removeValue(forKey: room)
        roomID = nil
        snapshot = .null
        roleRevealed = false
        persistState()
    }

    func watch(room: String) async throws {
        guard let backend, UUID(uuidString: room) != nil else { throw LabFailure(code: "invalid_room") }
        if watchingRoom == room && realtime == "subscribed" { _ = try await refresh(room: room); return }
        guard !watchInFlight else { throw LabFailure(code: "watch_in_progress") }
        watchInFlight = true; defer { watchInFlight = false }
        watchingRoom = room; realtimePaused = false
        try await backend.watch(roomID: room)
        _ = try await refresh(room: room)
        persistState()
    }

    func disconnectRealtime() {
        realtimePaused = true; backend?.disconnectRealtime(); realtime = "disconnected"; persistState()
    }

    func reconnectRealtime() async throws {
        guard let room = watchingRoom ?? roomID else { throw LabFailure(code: "no_active_room") }
        try await watch(room: room)
    }

    private func stopWatch() {
        watchingRoom = nil; realtimePaused = true; backend?.disconnectRealtime()
    }

    private func startReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self else { return }
                await self.reconcile(reason: "periodic")
                if !self.realtimePaused, !self.watchInFlight, self.realtime == "disconnected", let room = self.watchingRoom {
                    try? await self.watch(room: room)
                }
            }
        }
    }

    private func reconcile(reason: String) async {
        guard !refreshInFlight, let room = watchingRoom ?? roomID else { return }
        refreshInFlight = true; defer { refreshInFlight = false }
        do { _ = try await refresh(room: room) }
        catch { lastError = safeFailure(error).code; persistState() }
    }

    var state: JSONValue {
        .object([
            "client_id": .string(clientID), "native": .bool(true),
            "build": .number(Double(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0),
            "user_id": userID.isEmpty ? .null : .string(userID), "name": .string(name),
            "room_id": roomID.map(JSONValue.string) ?? .null, "revision": snapshot["revision"],
            "phase": .string(phase), "snapshot": snapshot, "realtime": .string(realtime),
            "signals": .array(signalRevisions.map { .number(Double($0)) }),
            "pending_ids": .array(pendingIDs.map(JSONValue.string)), "last_error": .string(lastError),
            "last_receipt": lastReceipt
        ])
    }

    private func record(_ error: Error) {
        let failure = safeFailure(error)
        lastError = failure.code
        status = "Test request needs attention"
        // Preserve the command failure across later successful reconciliation.
        // No credentials, payloads, private roles or words enter this journal.
        let url = evidenceDirectory.appendingPathComponent("failure-events.json")
        var events = ((try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }?.array ?? [])
            .filter { $0["actor_id"].string == userID }
        events.append(.object([
            "at": .string(ISO8601DateFormatter().string(from: Date())),
            "actor_id": .string(userID), "code": .string(failure.code),
            "ambiguous": .bool(failure.ambiguous), "revision": snapshot["revision"],
            "pending_ids": .array(pendingIDs.map(JSONValue.string))
        ]))
        try? JSONValue.array(Array(events.suffix(50))).data().write(to: url, options: .atomic)
        persistState()
    }

    private var evidenceDirectory: URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func persistState() { try? state.data().write(to: evidenceDirectory.appendingPathComponent("state.json"), options: .atomic) }
    private func persistPending() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(Array(pending.values)).write(to: evidenceDirectory.appendingPathComponent("pending-commands.json"), options: .atomic)
    }
    private func restorePending() {
        guard let data = try? Data(contentsOf: evidenceDirectory.appendingPathComponent("pending-commands.json")),
              let values = try? JSONDecoder().decode([Intent].self, from: data) else { return }
        pending = Dictionary(uniqueKeysWithValues: values.filter { $0.actorID == userID }.map { ($0.requestID, $0) })
        intents.merge(pending) { existing, _ in existing }
    }

    private func emit(_ event: String, controlID: String? = nil, result: JSONValue? = nil, failure: LabFailure? = nil) async {
        guard let controller else { return }
        eventSequence += 1
        var payload: [String: JSONValue] = ["event": .string(event), "client_id": .string(clientID),
            "sequence": .number(Double(eventSequence)), "ok": .bool(failure == nil), "state": state]
        if let controlID { payload["control_id"] = .string(controlID) }
        if let result { payload["result"] = result }
        if let failure { payload["error"] = failure.json }
        try? await controller.post(.object(payload))
    }

    private func pollController() async {
        guard let controller else { return }
        while !Task.isCancelled {
            do {
                if let action = try await controller.next() {
                    let id = action["id"].string ?? "missing"
                    do {
                        let result = try await executeControl(action)
                        await emit("result", controlID: id, result: result)
                    } catch { let failure = safeFailure(error); record(failure); await emit("result", controlID: id, failure: failure) }
                } else { try await Task.sleep(for: .milliseconds(200)) }
            } catch { try? await Task.sleep(for: .seconds(1)) }
        }
    }

    private func executeControl(_ action: JSONValue) async throws -> JSONValue {
        switch action["op"].string {
        case "command":
            guard let room = action["room_id"].string, let command = action["action"].string else { throw LabFailure(code: "invalid_control_command") }
            return try await self.command(room: room, action: command,
                payload: action["payload"].isNull ? .object([:]) : action["payload"], requestID: action["request_id"].string)
        case "snapshot": return try await refresh(room: action["room_id"].string ?? roomID ?? "")
        case "watch": try await watch(room: action["room_id"].string ?? roomID ?? ""); return state
        case "retry": return try await retry(requestID: action["request_id"].string ?? "")
        case "disconnect_realtime": disconnectRealtime(); return state
        case "reconnect_realtime": try await reconnectRealtime(); return state
        case "state": return state
        default: throw LabFailure(code: "unsupported_control_operation")
        }
    }
}

/// The fixture never performs a game action on behalf of the app. It only
/// supplies synthetic credentials and immutable intents; native networking acts.
final class NativeController: @unchecked Sendable {
    private let base: URL
    private let token: String
    private let clientID: String
    private let session: URLSession

    init(base: String, token: String, clientID: String) throws {
        self.base = try LabConfiguration.loopbackURL(base)
        guard token.count >= 20, !clientID.isEmpty, clientID.range(of: "^[a-zA-Z0-9_-]{1,40}$", options: .regularExpression) != nil else {
            throw LabFailure(code: "invalid_control_identity")
        }
        self.token = token; self.clientID = clientID
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 8; config.urlCache = nil
        session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func configuration() async throws -> LabConfiguration {
        let data = try await request("config")
        return try JSONDecoder().decode(LabConfiguration.self, from: data)
    }
    func next() async throws -> JSONValue? {
        let data = try await request("next")
        return data.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: data)
    }
    func post(_ value: JSONValue) async throws { _ = try await request("events", body: value.data()) }

    private func request(_ route: String, body: Data? = nil) async throws -> Data {
        let url = base.appendingPathComponent("clients").appendingPathComponent(clientID).appendingPathComponent(route)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpMethod = "POST"; request.httpBody = body }
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw LabFailure(code: "control_request_failed")
        }
        return data
    }
}
