#if SPYCLASH_SUPABASE
import Foundation

struct SupabaseSocialSignal: Equatable, Sendable {
    let table: String
    let profileUserID: String?
    let revision: Int

    /// Signals only invalidate cached views; the authenticated API remains authoritative.
    static func decode(_ payload: JSONValue, recipientUserID: String) -> Self? {
        let data = payload["data"], record = data["record"]
        guard data["schema"].string == "public",
              ["INSERT", "UPDATE"].contains(data["type"].string ?? ""),
              record["recipient_user_id"].string?.lowercased() == recipientUserID.lowercased(),
              case .number(let revision) = record["revision"], revision.isFinite,
              revision > 0, revision < Double(Int.max), revision.rounded() == revision,
              let table = data["table"].string else { return nil }
        switch table {
        case "app_user_signals": return Self(table: table, profileUserID: nil, revision: Int(revision))
        case "app_profile_signals":
            guard let profile = record["profile_user_id"].string, UUID(uuidString: profile) != nil else { return nil }
            return Self(table: table, profileUserID: profile.lowercased(), revision: Int(revision))
        default: return nil
        }
    }
}

protocol SupabaseSocialRealtimeSocket: AnyObject, Sendable {
    func resume()
    func cancel()
    func send(_ frame: JSONValue) async throws
    func receive() async throws -> JSONValue
}

private final class SupabaseSocialURLSocket: SupabaseSocialRealtimeSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    init(url: URL) { task = URLSession.shared.webSocketTask(with: url) }
    func resume() { task.resume() }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
    func send(_ frame: JSONValue) async throws {
        try await task.send(.string(String(decoding: try frame.data(), as: UTF8.self)))
    }
    func receive() async throws -> JSONValue {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: throw URLError(.cannotParseResponse)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

/// A recipient-scoped stream with catch-up after every confirmed subscription.
/// Task closures never hold the service across suspension, so view removal releases it.
@MainActor
final class SupabaseSocialRealtimeService {
    struct Account: Equatable {
        let userID: String
        let generation: UUID
    }
    struct Dependencies {
        var account: () -> Account
        var endpoint: () throws -> URL
        var accessToken: () async throws -> String
        var makeSocket: (URL) -> any SupabaseSocialRealtimeSocket
        var heartbeatInterval: Duration = .seconds(20)
        var timeout: Duration = .seconds(15)
        var retryDelay: (Int) -> Duration = { attempt in
            .seconds(min(30, pow(2, Double(min(attempt, 5)))) + Double.random(in: 0...0.5))
        }
    }

    var onChange: ((SupabaseSocialSignal) -> Void)?
    var onCatchUp: (() -> Void)?
    private let dependencies: Dependencies
    private var account: Account?
    private var connectionID = UUID()
    private var socket: (any SupabaseSocialRealtimeSocket)?
    private var connectTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var tokenTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var heartbeatDeadlineTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var sequence = 1
    private var pendingHeartbeat: String?
    private var subscriptionIDs: [String: Int] = [:]
    private var postgresReady = false
    private var subscribed = false
    private var revisions: [String: Int] = [:]
    private static let tables = ["app_user_signals", "app_profile_signals"]

    convenience init(auth: SupabaseAppSession? = nil) {
        let auth = auth ?? .shared
        self.init(dependencies: Dependencies(
            account: { Account(userID: auth.userID, generation: auth.generation) },
            endpoint: {
                let configuration = try auth.configuration()
                guard var url = URLComponents(string: configuration.backendURL) else { throw URLError(.badURL) }
                url.scheme = "wss"; url.path = "/realtime/v1/websocket"
                url.queryItems = [URLQueryItem(name: "apikey", value: configuration.publishableKey), URLQueryItem(name: "vsn", value: "1.0.0")]
                guard let endpoint = url.url else { throw URLError(.badURL) }
                return endpoint
            },
            accessToken: { try await auth.ensureAccessToken() },
            makeSocket: { SupabaseSocialURLSocket(url: $0) }
        ))
    }

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    deinit {
        connectTask?.cancel(); receiveTask?.cancel(); heartbeatTask?.cancel(); tokenTask?.cancel()
        deadlineTask?.cancel(); heartbeatDeadlineTask?.cancel(); retryTask?.cancel(); socket?.cancel()
    }

    func start(userID: String) {
        let current = dependencies.account()
        guard UUID(uuidString: userID) != nil, current.userID.lowercased() == userID.lowercased() else { stop(); return }
        guard account != current else { return }
        stop(); account = current; connect()
    }

    func stop() {
        account = nil; retryTask?.cancel(); retryTask = nil
        closeConnection(); retryAttempt = 0; revisions.removeAll()
    }

    private var topic: String { "realtime:app-social-\(account?.userID.lowercased() ?? "")" }
    private func isCurrent(_ connection: UUID) -> Bool {
        connectionID == connection && account != nil && dependencies.account() == account
    }
    private func requireCurrent(_ connection: UUID) throws {
        try Task.checkCancellation()
        guard isCurrent(connection) else { throw CancellationError() }
    }

    private func connect() {
        guard let account, dependencies.account() == account else { stop(); return }
        closeConnection()
        let connection = connectionID, dependencies = dependencies, topic = topic
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: dependencies.timeout) } catch { return }
            self?.failed(connection)
        }
        connectTask = Task { [weak self] in
            do {
                guard self?.isCurrent(connection) == true, !Task.isCancelled else { return }
                let token = try await dependencies.accessToken()
                guard let active = self?.isCurrent(connection), active, !Task.isCancelled else { self?.failed(connection); return }
                let socket = dependencies.makeSocket(try dependencies.endpoint())
                self?.install(socket, connection: connection)
                socket.resume()
                let subscriptions = Self.tables.map { table in JSONValue.object([
                    "event": .string("*"), "schema": .string("public"), "table": .string(table),
                    "filter": .string("recipient_user_id=eq.\(account.userID.lowercased())")
                ]) }
                try await socket.send(Self.frame(topic: topic, event: "phx_join", ref: "1", payload: .object([
                    "access_token": .string(token), "config": .object([
                        "broadcast": .object(["ack": .bool(false), "self": .bool(false)]),
                        "presence": .object(["enabled": .bool(false)]), "private": .bool(false),
                        "postgres_changes": .array(subscriptions)
                    ])
                ])))
                try self?.requireCurrent(connection)
            } catch { self?.failed(connection) }
        }
    }

    private func install(_ socket: any SupabaseSocialRealtimeSocket, connection: UUID) {
        self.socket = socket
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try self?.requireCurrent(connection)
                    let frame = try await socket.receive()
                    guard self?.isCurrent(connection) == true, !Task.isCancelled else { self?.failed(connection); return }
                    try self?.handle(frame, connection: connection)
                }
            } catch { self?.failed(connection) }
        }
    }

    private func handle(_ frame: JSONValue, connection: UUID) throws {
        let event = frame["event"].string, payload = frame["payload"]
        if frame["topic"].string == "phoenix", event == "phx_reply", frame["ref"].string == pendingHeartbeat {
            guard payload["status"].string == "ok" else { throw URLError(.networkConnectionLost) }
            pendingHeartbeat = nil; heartbeatDeadlineTask?.cancel(); heartbeatDeadlineTask = nil
            return
        }
        guard frame["topic"].string == topic else { return }
        switch event {
        case "phx_reply" where frame["ref"].string == "1":
            guard payload["status"].string == "ok" else { throw URLError(.userAuthenticationRequired) }
            var ids: [String: Int] = [:]
            for binding in payload["response"]["postgres_changes"].array {
                guard let table = binding["table"].string, Self.tables.contains(table),
                      binding["schema"].string == "public", binding["event"].string == "*",
                      (binding["filter"].isNull || binding["filter"].string == "recipient_user_id=eq.\(account!.userID.lowercased())"),
                      case .number(let id) = binding["id"], id >= 0, id < Double(Int.max), id.rounded() == id else {
                    throw URLError(.cannotParseResponse)
                }
                ids[table] = Int(id)
            }
            guard ids.count == Self.tables.count, Set(ids.values).count == Self.tables.count else { throw URLError(.cannotParseResponse) }
            subscriptionIDs = ids; finishSubscription(connection)
        case "system":
            guard payload["status"].string == "ok" else { throw URLError(.networkConnectionLost) }
            if payload["extension"].string == "postgres_changes" { postgresReady = true; finishSubscription(connection) }
        case "phx_error", "phx_close": throw URLError(.networkConnectionLost)
        case "phx_reply" where payload["status"].string == "error": throw URLError(.networkConnectionLost)
        case "postgres_changes":
            guard subscribed, let account, let signal = SupabaseSocialSignal.decode(payload, recipientUserID: account.userID) else { return }
            guard let id = subscriptionIDs[signal.table], payload["ids"].array.contains(.number(Double(id))) else {
                throw URLError(.cannotParseResponse)
            }
            let key = signal.table + ":" + (signal.profileUserID ?? "")
            guard signal.revision > (revisions[key] ?? 0) else { return }
            revisions[key] = signal.revision; onChange?(signal)
        default: break
        }
    }

    private func finishSubscription(_ connection: UUID) {
        guard !subscribed, postgresReady, subscriptionIDs.count == Self.tables.count else { return }
        subscribed = true; retryAttempt = 0; deadlineTask?.cancel(); deadlineTask = nil
        startKeepAlive(connection)
        onCatchUp?()
    }

    private func startKeepAlive(_ connection: UUID) {
        guard let socket else { return }
        let dependencies = dependencies, topic = topic
        heartbeatTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: dependencies.heartbeatInterval)
                    guard self?.isCurrent(connection) == true, !Task.isCancelled else { self?.failed(connection); return }
                    guard let ref = self?.beginHeartbeat(connection) else { return }
                    try await socket.send(Self.frame(topic: "phoenix", event: "heartbeat", ref: ref, payload: .object([:])))
                    try self?.requireCurrent(connection)
                }
            } catch { self?.failed(connection) }
        }
        // Token refresh must not delay Phoenix heartbeats while the auth request is in flight.
        tokenTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: dependencies.heartbeatInterval)
                    try self?.requireCurrent(connection)
                    let token = try await dependencies.accessToken()
                    guard self?.isCurrent(connection) == true, !Task.isCancelled else { self?.failed(connection); return }
                    guard let ref = self?.nextRef() else { return }
                    try await socket.send(Self.frame(topic: topic, event: "access_token", ref: ref, payload: .object(["access_token": .string(token)])))
                    try self?.requireCurrent(connection)
                }
            } catch { self?.failed(connection) }
        }
    }

    private func beginHeartbeat(_ connection: UUID) -> String? {
        guard pendingHeartbeat == nil else { failed(connection); return nil }
        let ref = nextRef(); pendingHeartbeat = ref
        let timeout = dependencies.timeout
        heartbeatDeadlineTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.failed(connection)
        }
        return ref
    }
    private func nextRef() -> String { sequence += 1; return String(sequence) }
    private static func frame(topic: String, event: String, ref: String, payload: JSONValue) -> JSONValue {
        .object(["topic": .string(topic), "event": .string(event), "ref": .string(ref), "join_ref": topic == "phoenix" ? .null : .string("1"), "payload": payload])
    }
    private func failed(_ connection: UUID) {
        guard connectionID == connection else { return }
        guard let account, dependencies.account() == account else { stop(); return }
        closeConnection()
        let delay = dependencies.retryDelay(retryAttempt); retryAttempt += 1
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.retryTask = nil; self?.connect()
        }
    }
    private func closeConnection() {
        connectionID = UUID()
        connectTask?.cancel(); receiveTask?.cancel(); heartbeatTask?.cancel(); tokenTask?.cancel()
        deadlineTask?.cancel(); heartbeatDeadlineTask?.cancel()
        connectTask = nil; receiveTask = nil; heartbeatTask = nil; tokenTask = nil
        deadlineTask = nil; heartbeatDeadlineTask = nil
        socket?.cancel(); socket = nil
        sequence = 1; pendingHeartbeat = nil; subscribed = false; postgresReady = false; subscriptionIDs.removeAll()
    }
}
#endif
