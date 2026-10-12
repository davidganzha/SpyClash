import Foundation

/// Only real URLSession Auth, REST and WebSocket requests. No fabricated game state.
@MainActor
final class BackendClient {
    let config: LabConfiguration
    private let session: URLSession
    private var accessToken = ""
    private var refreshToken = ""
    private var expiresAt = Date.distantPast
    private(set) var userID = ""
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var joinTimeoutTask: Task<Void, Never>?
    private var joinContinuation: CheckedContinuation<Void, Error>?
    private var connectionID = UUID()
    var onRealtime: ((String, JSONValue?) -> Void)?

    init(config: LabConfiguration) throws {
        self.config = try config.validated()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 18
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func signIn() async throws {
        let response = try await request(path: "/auth/v1/token?grant_type=password", body: .object([
            "email": .string(config.email), "password": .string(config.password)
        ]), authenticated: false)
        try acceptSession(response)
    }

    private func acceptSession(_ response: JSONValue) throws {
        guard let token = response["access_token"].string, let refresh = response["refresh_token"].string,
              let id = response["user"]["id"].string else { throw LabFailure(code: "auth_session_missing") }
        accessToken = token; refreshToken = refresh; userID = id
        expiresAt = Date().addingTimeInterval(TimeInterval(response["expires_in"].integer))
    }

    private func ensureSession() async throws {
        guard !accessToken.isEmpty else { throw LabFailure(code: "not_signed_in") }
        if expiresAt.timeIntervalSinceNow < 60 {
            let response = try await request(path: "/auth/v1/token?grant_type=refresh_token", body: .object([
                "refresh_token": .string(refreshToken)
            ]), authenticated: false)
            try acceptSession(response)
        }
    }

    func rpc(_ name: String, body: JSONValue) async throws -> JSONValue {
        guard ["game_command", "game_snapshot"].contains(name) else { throw LabFailure(code: "unsupported_rpc") }
        try await ensureSession()
        return try await request(path: "/rest/v1/rpc/\(name)", body: body, authenticated: true)
    }

    private func request(path: String, body: JSONValue, authenticated: Bool) async throws -> JSONValue {
        let base = (config.transportURL ?? config.backendURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else { throw LabFailure(code: "invalid_request_url") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try body.data()
        let data: Data
        let rawResponse: URLResponse
        do { (data, rawResponse) = try await session.data(for: request) }
        catch { throw safeFailure(error) }
        guard let response = rawResponse as? HTTPURLResponse else { throw LabFailure(code: "missing_http_response", ambiguous: true) }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        guard (200..<300).contains(response.statusCode) else {
            let code = json["code"].string ?? json["error_code"].string ?? "http_\(response.statusCode)"
            // Postgres business errors are definitive transaction rejections.
            let message = code == "P0001" ? (json["message"].string ?? code) : code
            throw LabFailure(code: message, ambiguous: response.statusCode >= 500)
        }
        guard !json.isNull else { throw LabFailure(code: "invalid_response_json", ambiguous: true) }
        return json
    }

    func watch(roomID: String) async throws {
        disconnectRealtime()
        try await ensureSession()
        var components = URLComponents(string: config.backendURL)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: config.publishableKey), URLQueryItem(name: "vsn", value: "1.0.0")]
        let task = session.webSocketTask(with: components.url!)
        let id = UUID(); connectionID = id; socket = task
        task.resume()
        onRealtime?("connecting", nil)
        let topic = "realtime:game-lab-\(roomID)-\(UUID().uuidString.lowercased())"
        let join: JSONValue = .object([
            "topic": .string(topic), "event": .string("phx_join"), "ref": .string("1"), "join_ref": .string("1"),
            "payload": .object([
                "access_token": .string(accessToken),
                "config": .object([
                    "broadcast": .object(["ack": .bool(false), "self": .bool(false)]),
                    "presence": .object(["enabled": .bool(false)]), "private": .bool(false),
                    "postgres_changes_options": .object(["wait": .bool(true), "timeout": .number(15000)]),
                    "postgres_changes": .array([.object([
                        "event": .string("*"), "schema": .string("public"), "table": .string("game_room_signals"),
                        "filter": .string("room_id=eq.\(roomID)")
                    ])])
                ])
            ])
        ])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            joinContinuation = continuation
            receiveTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await task.send(.string(String(decoding: try join.data(), as: UTF8.self)))
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard self.connectionID == id else { return }
                        let data: Data
                        switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                        let frame = try JSONDecoder().decode(JSONValue.self, from: data)
                        switch frame["event"].string {
                        case "phx_reply" where frame["ref"].string == "1":
                            guard frame["payload"]["status"].string == "ok" else { throw LabFailure(code: "realtime_join_rejected") }
                            self.resolveJoin(nil)
                            self.onRealtime?("subscribed", nil)
                        case "postgres_changes": self.onRealtime?("signal", frame["payload"]["data"]["record"])
                        case "system":
                            if frame["payload"]["status"].string == "error" { throw LabFailure(code: "realtime_subscription_error") }
                        case "phx_error", "phx_close": throw LabFailure(code: "realtime_closed")
                        default: break
                        }
                    }
                } catch {
                    guard self.connectionID == id else { return }
                    self.resolveJoin(safeFailure(error)); self.onRealtime?("disconnected", nil)
                }
            }
            joinTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.connectionID == id, self.joinContinuation != nil else { return }
                self.resolveJoin(LabFailure(code: "realtime_join_timeout")); self.disconnectRealtime()
            }
        }
        heartbeatTask = Task { [weak self] in
            var sequence = 1
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.connectionID == id else { return }
                sequence += 1
                let heartbeat: JSONValue = .object(["topic": .string("phoenix"), "event": .string("heartbeat"), "payload": .object([:]), "ref": .string(String(sequence))])
                do { try await task.send(.string(String(decoding: try heartbeat.data(), as: UTF8.self))) }
                catch { self.disconnectRealtime(); return }
            }
        }
    }

    private func resolveJoin(_ error: Error?) {
        guard let continuation = joinContinuation else { return }
        joinContinuation = nil; joinTimeoutTask?.cancel()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func disconnectRealtime() {
        connectionID = UUID()
        resolveJoin(LabFailure(code: "realtime_cancelled"))
        receiveTask?.cancel(); heartbeatTask?.cancel(); joinTimeoutTask?.cancel()
        receiveTask = nil; heartbeatTask = nil; joinTimeoutTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        onRealtime?("disconnected", nil)
    }
}
