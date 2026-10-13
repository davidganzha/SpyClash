#if SPYCLASH_SUPABASE
import Foundation
import Security

/// Credentials belong to a project and app bundle, separate from Base44 and the game lab.
struct SupabaseStoredSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let userID: String
    let expiresAt: Date
}

enum SupabaseSessionKeychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.spyclash.ios.supabasetest") + ".supabase.bbkfsgnordtdiblgdzkg" }
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session-v1"]
    }
    static func read() -> SupabaseStoredSession? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SupabaseStoredSession.self, from: data)
    }
    static func save(_ session: SupabaseStoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw storageFailure }
        var query = identity
        attributes.forEach { query[$0.key] = $0.value }
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw storageFailure }
    }
    static func clear() { SecItemDelete(identity as CFDictionary) }
    private static var storageFailure: Base44Error { Base44Error(message: "The account session could not be saved securely.", code: "session_storage_failed") }
}

@MainActor
final class SupabaseAppSession {
    static let shared = SupabaseAppSession()
    private let configurationResult: Result<SupabaseAppConfiguration, Error>
    private let http: URLSession
    private let persistSession: (SupabaseStoredSession) throws -> Void
    private let removeSession: () -> Void
    private let mutationJournal: SupabaseAppMutationJournal
    private let persistLegacy: (SupabaseLegacyCredential) throws -> Void
    private let removeLegacy: () -> Void
    private(set) var legacyCredential: SupabaseLegacyCredential?
    private var legacyCandidates: [String: SupabaseLegacyCredential] = [:]
    private(set) var session: SupabaseStoredSession?
    private(set) var generation = UUID()
    private var candidates: [String: SupabaseStoredSession] = [:]
    private var refreshTask: Task<SupabaseStoredSession, Error>?
    var accessToken: String? { session?.accessToken }
    var userID: String { session?.userID ?? "" }

    init(configuration: SupabaseAppConfiguration? = nil, session: URLSession? = nil, storedSession: SupabaseStoredSession? = SupabaseSessionKeychain.read(), saveSession: @escaping (SupabaseStoredSession) throws -> Void = SupabaseSessionKeychain.save, clearSession: @escaping () -> Void = SupabaseSessionKeychain.clear, mutationJournal: SupabaseAppMutationJournal = SupabaseAppMutationJournal(), storedLegacy: SupabaseLegacyCredential? = SupabaseLegacyKeychain.read(), saveLegacy: @escaping (SupabaseLegacyCredential) throws -> Void = SupabaseLegacyKeychain.save, clearLegacy: @escaping () -> Void = SupabaseLegacyKeychain.clear) {
        persistSession = saveSession; removeSession = clearSession
        self.mutationJournal = mutationJournal
        persistLegacy = saveLegacy; removeLegacy = clearLegacy
        legacyCredential = storedLegacy?.actorID == storedSession?.userID ? storedLegacy : nil
        configurationResult = Result { try configuration?.validated() ?? SupabaseAppConfiguration.bundled() }
        if let session { http = session }
        else {
            let config = Self.transportConfiguration()
            http = URLSession(configuration: config, delegate: SupabaseNoRedirectDelegate(), delegateQueue: nil)
        }
        self.session = storedSession
    }

    static func transportConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 95
        config.waitsForConnectivity = false
        return config
    }

    func configuration() throws -> SupabaseAppConfiguration { try configurationResult.get() }

    /// A candidate is committed only after AppState validates ownership of the auth attempt.
    func commit(accessToken: String) throws {
        guard let candidate = candidates[accessToken] else {
            guard session?.accessToken == accessToken else { throw Self.invalidSession }
            return
        }
        guard let legacy = legacyCandidates[accessToken], legacy.actorID == candidate.userID else { throw Self.invalidSession }
        let previousLegacy = legacyCredential
        try persistLegacy(legacy)
        do { try persistSession(candidate) }
        catch {
            if let previousLegacy { try? persistLegacy(previousLegacy) } else { removeLegacy() }
            throw error
        }
        legacyCredential = legacy
        refreshTask?.cancel(); refreshTask = nil
        session = candidate; candidates.removeAll(); legacyCandidates.removeAll()
        generation = UUID()
    }

    func clear(revokeRemote: Bool = true) {
        let old = session
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        session = nil; candidates.removeAll(); legacyCandidates.removeAll(); legacyCredential = nil
        removeSession(); removeLegacy()
        SupabaseGameAdapter.shared.disconnect()
        if let old, revokeRemote {
            Task { try? await self.request(path: "/auth/v1/logout?scope=local", method: "POST", body: .object([:]), token: old.accessToken) }
        }
    }

    /// The exchange verifies the Base44 identity on the server. Local profile fields are never trusted.
    func exchangeLegacySession(_ legacyToken: String) async throws -> LoginResponse {
        guard !legacyToken.isEmpty, !SupabaseLegacyAuth.isSupabaseBearer(legacyToken), legacyToken != session?.accessToken,
              candidates[legacyToken] == nil else { throw Self.invalidSession }
        let epoch = generation
        let response = try await legacyExchange(legacyToken, epoch: epoch)
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        let candidate = try Self.decodeSession(response)
        guard let legacyID = response["legacy_user_id"].string, !legacyID.isEmpty, legacyID.count <= 512,
              candidate.accessToken != legacyToken else { throw Self.invalidSession }
        candidates = [candidate.accessToken: candidate]
        legacyCandidates = [candidate.accessToken: SupabaseLegacyCredential(actorID: candidate.userID, legacyUserID: legacyID, accessToken: legacyToken)]
        let user = try await profile(accessToken: candidate.accessToken)
        guard epoch == generation, candidates[candidate.accessToken] != nil else { throw CancellationError() }
        return LoginResponse(accessToken: candidate.accessToken, user: user)
    }

    private func legacyExchange(_ legacyToken: String, epoch: UUID) async throws -> JSONValue {
        var retries = 0
        var importRetries = 0
        while true {
            guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
            do { return try await request(path: "/functions/v1/legacy-session", method: "POST", body: .object(["action": .string("exchange")]), token: legacyToken) }
            catch let error as Base44Error where ["legacy_session_busy", "LEGACY_SESSION_BUSY"].contains(error.code ?? "") && retries < 2 {
                retries += 1
                try await Task.sleep(for: .seconds(1))
            } catch let error as Base44Error where ["legacy_import_pending", "LEGACY_IMPORT_PENDING"].contains(error.code ?? "") {
                guard importRetries < 8 else {
                    throw Base44Error(message: "Your existing SpyClash data is still being transferred. Sign in again to continue safely.", statusCode: 503, code: "legacy_import_pending", retryable: true)
                }
                importRetries += 1
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    func legacyAccessToken() throws -> String {
        guard let session, let legacyCredential, legacyCredential.actorID == session.userID,
              !legacyCredential.accessToken.isEmpty, !SupabaseLegacyAuth.isSupabaseBearer(legacyCredential.accessToken), legacyCredential.accessToken != session.accessToken else {
            throw Base44Error(message: "Sign in again with your Base44 account to use this feature.", statusCode: 401, code: "legacy_session_missing")
        }
        return legacyCredential.accessToken
    }

    func profile(accessToken: String? = nil) async throws -> SpyUser {
        let expectedActor = accessToken.flatMap { candidates[$0]?.userID } ?? session?.userID
        let user: SpyUser = try await service("profile", action: "current", token: accessToken)
        guard let expectedActor, user.id.lowercased() == expectedActor,
              user.email == expectedActor + "@example.test" else {
            throw Base44Error(message: "The account profile could not be verified.", code: "invalid_account_profile")
        }
        return user
    }
    func ensureAccessToken(forceLegacyValidation: Bool = false) async throws -> String {
        guard let current = session else { throw Self.invalidSession }
        if !forceLegacyValidation, current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let epoch = generation
        let legacyToken = try legacyAccessToken()
        let legacyID = legacyCredential?.legacyUserID
        let task = Task { @MainActor in
            let json = try await self.legacyExchange(legacyToken, epoch: epoch)
            let next = try Self.decodeSession(json)
            guard self.generation == epoch, !Task.isCancelled else { throw CancellationError() }
            guard self.session?.userID == next.userID, json["legacy_user_id"].string == legacyID else { throw Self.invalidSession }
            try self.persistSession(next)
            self.session = next
            return next
        }
        refreshTask = task
        defer { if generation == epoch { refreshTask = nil } }
        return try await task.value.accessToken
    }
    func service<T: Decodable>(_ service: String, action: String, fields: [String: JSONValue] = [:], write: Bool = false, token: String? = nil, includeLegacyCredential: Bool = false) async throws -> T {
        var body = fields
        body.removeValue(forKey: "access_token")
        body["service"] = .string(service); body["action"] = .string(action)
        let epoch = generation
        let credential: String
        if let token { credential = token } else { credential = try await ensureAccessToken() }
        guard epoch == generation else { throw CancellationError() }
        let actorID = userID
        let legacyToken = includeLegacyCredential ? try legacyAccessToken() : nil
        guard !includeLegacyCredential || (service == "legacy" && ["link", "generate"].contains(action)) else { throw Self.invalidSession }
        if write { body = try mutationJournal.prepare(actorID: actorID, body: body) }
        do {
            var wireBody = body
            if let legacyToken { wireBody["base44_access_token"] = .string(legacyToken) }
            let value = try await request(path: "/functions/v1/app-services", method: "POST", body: .object(wireBody), token: credential)
            guard epoch == generation else { throw CancellationError() }
            let result = try JSONDecoder.base44.decode(T.self, from: value.data())
            if write, let requestID = body["request_id"]?.string { try mutationJournal.acknowledge(actorID: actorID, requestID: requestID) }
            return result
        } catch let error as Base44Error {
            if write, let status = error.statusCode, (400..<500).contains(status), let requestID = body["request_id"]?.string {
                try mutationJournal.acknowledge(actorID: actorID, requestID: requestID)
            }
            throw error
        }
    }
    func fullGame(_ body: JSONValue) async throws -> JSONValue {
        let epoch = generation
        let token = try await ensureAccessToken()
        do {
            let result = try await request(path: "/functions/v1/full-game-core", method: "POST", body: body, token: token)
            guard epoch == generation else { throw CancellationError() }
            return result
        } catch let error as Base44Error {
            throw FullGameTransportFailure(error: error, ambiguous: !(400..<500).contains(error.statusCode ?? 0))
        }
    }
    static func decodeSession(_ value: JSONValue) throws -> SupabaseStoredSession {
        guard let access = value["access_token"].string, !access.isEmpty,
              let refresh = value["refresh_token"].string, !refresh.isEmpty,
              let user = value["user"]["id"].string, UUID(uuidString: user) != nil,
              value["expires_in"].integer > 0 else { throw invalidSession }
        return SupabaseStoredSession(accessToken: access, refreshToken: refresh, userID: user.lowercased(), expiresAt: Date().addingTimeInterval(TimeInterval(value["expires_in"].integer)))
    }
    private func request(path: String, method: String, body: JSONValue, token: String? = nil) async throws -> JSONValue {
        let configuration = try configuration()
        guard path.hasPrefix("/auth/v1/") || ["/functions/v1/app-services", "/functions/v1/full-game-core", "/functions/v1/legacy-session"].contains(path),
              let url = URL(string: configuration.backendURL + path), url.host == "bbkfsgnordtdiblgdzkg.supabase.co" else { throw Self.invalidSession }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if path == "/functions/v1/legacy-session" { request.timeoutInterval = 90 }
        else if path == "/functions/v1/app-services", body["service"].string == "legacy", body["action"].string == "generate" { request.timeoutInterval = 75 }
        else { request.timeoutInterval = 20 }
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try body.data()
        let data: Data; let response: URLResponse
        do { (data, response) = try await http.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw Base44Error(message: "Connection interrupted. Please try again.", statusCode: 503, code: "supabase_transport_interrupted", retryable: true)
        }
        guard let response = response as? HTTPURLResponse else { throw Self.invalidSession }
        let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([:])
        guard (200..<300).contains(response.statusCode) else {
            let details = json["error"].object == nil ? json : json["error"]
            throw Base44Error(message: details["message"].string ?? details["msg"].string ?? details["error_description"].string ?? "The request could not be completed.", statusCode: response.statusCode, code: details["code"].string ?? details["error_code"].string ?? details["error"].string ?? "http_\(response.statusCode)", retryable: response.statusCode >= 500 || details["retryable"].bool)
        }
        return json
    }
    private static var invalidSession: Base44Error { Base44Error(message: "Please sign in again.", statusCode: 401, code: "supabase_session_missing") }
}

private final class SupabaseNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif
