#if SPYCLASH_SUPABASE
import Foundation

/// The gameplay journal and app services share one account session, never a fixture password.
@MainActor
final class SupabaseAppGameTransport: SupabaseFullGameTransport {
    private let auth: SupabaseAppSession
    private let actorID: String
    private let accountGeneration: UUID
    var userID: String { actorID }
    var onRealtime: ((String, JSONValue?) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var receiving: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var joinTimeout: Task<Void, Never>?
    private var joinContinuation: CheckedContinuation<Void, Error>?
    private var connectionID = UUID()

    init(auth: SupabaseAppSession = .shared) {
        self.auth = auth; actorID = auth.userID; accountGeneration = auth.generation
    }
    private func requireAccount() throws {
        guard auth.userID == actorID, auth.generation == accountGeneration else { throw CancellationError() }
    }
    func fullGame(_ body: JSONValue) async throws -> JSONValue {
        try requireAccount()
        let response = try await auth.fullGame(body)
        try requireAccount()
        return response
    }
    func watch(roomID: String, table: String) async throws {
        guard table == "full_game_room_signals", UUID(uuidString: roomID) != nil else { throw SupabaseFullGameStore.invalidResponse }
        try Task.checkCancellation()
        try requireAccount()
        disconnectRealtime()
        let config = try auth.configuration()
        let token = try await auth.ensureAccessToken()
        try Task.checkCancellation()
        try requireAccount()
        var components = URLComponents(string: config.backendURL)!
        components.scheme = "wss"; components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: config.publishableKey), URLQueryItem(name: "vsn", value: "1.0.0")]
        let ws = URLSession.shared.webSocketTask(with: components.url!)
        let connection = UUID(); connectionID = connection; socket = ws
        ws.resume(); onRealtime?("connecting", nil)
        let topic = "realtime:app-game-\(roomID)"
        let join: JSONValue = .object([
            "topic": .string(topic), "event": .string("phx_join"), "ref": .string("1"), "join_ref": .string("1"),
            "payload": .object(["access_token": .string(token), "config": .object([
                "broadcast": .object(["ack": .bool(false), "self": .bool(false)]), "presence": .object(["enabled": .bool(false)]), "private": .bool(false),
                "postgres_changes": .array([.object(["event": .string("*"), "schema": .string("public"), "table": .string(table), "filter": .string("room_id=eq.\(roomID)")])])
            ])])
        ])
        try await ws.send(.string(String(decoding: try join.data(), as: UTF8.self)))
        try Task.checkCancellation()
        try requireAccount()
        guard connectionID == connection else { throw CancellationError() }
        // The receive loop owns acknowledgement. Reconciliation also polls the authoritative API.
        receiving = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    try self.requireAccount()
                    guard self.connectionID == connection else { return }
                    let data: Data
                    switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    let frame = try JSONDecoder().decode(JSONValue.self, from: data)
                    switch frame["event"].string {
                    case "phx_reply" where frame["ref"].string == "1":
                        guard frame["payload"]["status"].string == "ok" else { throw SupabaseFullGameStore.invalidResponse }
                        self.resolveJoin(nil)
                        self.onRealtime?("subscribed", nil)
                    case "postgres_changes": self.onRealtime?("signal", frame["payload"]["data"]["record"])
                    case "phx_error", "phx_close": throw SupabaseFullGameStore.invalidResponse
                    default: break
                    }
                }
            } catch {
                guard self.connectionID == connection else { return }
                self.resolveJoin(error)
                self.disconnectRealtime()
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            joinContinuation = continuation
            joinTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.connectionID == connection, self.joinContinuation != nil else { return }
                self.resolveJoin(Base44Error(message: "Realtime subscription timed out.", statusCode: 503, code: "realtime_join_timeout", retryable: true))
                self.disconnectRealtime()
            }
        }
        try Task.checkCancellation()
        try requireAccount()
        guard connectionID == connection else { throw CancellationError() }
        heartbeat = Task { [weak self] in
            var sequence = 1
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(20))
                    guard let self, self.connectionID == connection else { return }
                    try self.requireAccount()
                    let currentToken = try await self.auth.ensureAccessToken()
                    sequence += 1
                    let refresh: JSONValue = .object(["topic": .string(topic), "event": .string("access_token"), "payload": .object(["access_token": .string(currentToken)]), "ref": .string(String(sequence))])
                    try await ws.send(.string(String(decoding: try refresh.data(), as: UTF8.self)))
                    sequence += 1
                    let beat: JSONValue = .object(["topic": .string("phoenix"), "event": .string("heartbeat"), "payload": .object([:]), "ref": .string(String(sequence))])
                    try await ws.send(.string(String(decoding: try beat.data(), as: UTF8.self)))
                } catch {
                    guard let self, self.connectionID == connection else { return }
                    self.disconnectRealtime(); return
                }
            }
        }
    }
    func disconnectRealtime() {
        resolveJoin(CancellationError())
        connectionID = UUID(); receiving?.cancel(); heartbeat?.cancel()
        receiving = nil; heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        onRealtime?("disconnected", nil)
    }
    private func resolveJoin(_ error: Error?) {
        guard let continuation = joinContinuation else { return }
        joinContinuation = nil; joinTimeout?.cancel(); joinTimeout = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
#endif
