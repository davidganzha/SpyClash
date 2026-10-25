#if SPYCLASH_SUPABASE
import Foundation
import Security

enum SupabaseNativeCredentialKind: String, Codable, Sendable {
    case gameCenter = "game_center"
    case email
}

/// Credentials belong to a project and app bundle, separate from Base44 and the game lab.
struct SupabaseStoredSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let userID: String
    let expiresAt: Date
    var nativeCredentialKind: SupabaseNativeCredentialKind? = nil
}

enum SupabaseSessionKeychain {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.spyclash.ios.supabasetest") + ".supabase." + SupabaseAppConfiguration.configuredProjectReference }
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
    private let appStoreRetrySleep: @MainActor (Duration) async throws -> Void
    private(set) var legacyCredential: SupabaseLegacyCredential?
    private var legacyCandidates: [String: SupabaseLegacyCredential] = [:]
    private(set) var session: SupabaseStoredSession?
    private(set) var generation = UUID()
    private var candidates: [String: SupabaseStoredSession] = [:]
    private var candidateExchangeID: UUID?
    private var refreshTask: Task<SupabaseStoredSession, Error>?
    // The existing cancellable FIFO primitive gives StoreKit its own queue;
    // this instance never serializes game or unrelated app-service commands.
    private let appStoreDeliveryQueue = RoomMutationQueue()
    var accessToken: String? { session?.accessToken }
    var userID: String { session?.userID ?? "" }

    init(configuration: SupabaseAppConfiguration? = nil, session: URLSession? = nil, storedSession: SupabaseStoredSession? = SupabaseSessionKeychain.read(), saveSession: @escaping (SupabaseStoredSession) throws -> Void = SupabaseSessionKeychain.save, clearSession: @escaping () -> Void = SupabaseSessionKeychain.clear, mutationJournal: SupabaseAppMutationJournal = SupabaseAppMutationJournal(), storedLegacy: SupabaseLegacyCredential? = SupabaseLegacyKeychain.read(), saveLegacy: @escaping (SupabaseLegacyCredential) throws -> Void = SupabaseLegacyKeychain.save, clearLegacy: @escaping () -> Void = SupabaseLegacyKeychain.clear, appStoreRetrySleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        persistSession = saveSession; removeSession = clearSession
        self.mutationJournal = mutationJournal
        persistLegacy = saveLegacy; removeLegacy = clearLegacy
        self.appStoreRetrySleep = appStoreRetrySleep
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
#if SPYCLASH_GAME_CENTER_EXPERIMENT
        if candidate.nativeCredentialKind != nil {
            try persistSession(candidate)
            removeLegacy(); legacyCredential = nil
            refreshTask?.cancel(); refreshTask = nil
            session = candidate; candidates.removeAll(); legacyCandidates.removeAll(); candidateExchangeID = nil
            generation = UUID()
            return
        }
#endif
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
        session = candidate; candidates.removeAll(); legacyCandidates.removeAll(); candidateExchangeID = nil
        generation = UUID()
    }

    func clear(revokeRemote: Bool = true) {
        let old = session
        generation = UUID(); refreshTask?.cancel(); refreshTask = nil
        session = nil; candidates.removeAll(); legacyCandidates.removeAll(); candidateExchangeID = nil; legacyCredential = nil
        removeSession(); removeLegacy()
        SupabaseGameAdapter.shared.disconnect()
        if let old, revokeRemote {
            Task { try? await self.request(path: "/auth/v1/logout?scope=local", method: "POST", body: .object([:]), token: old.accessToken) }
        }
    }

    /// The exchange verifies the Base44 identity on the server. Local profile fields are never trusted.
    func exchangeLegacySession(
        _ legacyToken: String,
        requireCurrentAttempt: @MainActor () throws -> Void = {}
    ) async throws -> LoginResponse {
        try Task.checkCancellation()
        try requireCurrentAttempt()
        guard SupabaseLegacyAuth.isValidCredential(legacyToken), !SupabaseLegacyAuth.isSupabaseBearer(legacyToken), legacyToken != session?.accessToken,
              candidates[legacyToken] == nil else { throw Self.invalidSession }
        let epoch = generation
        // A new sign-in can supersede an old exchange without replacing the
        // saved account. Its candidate ownership is separate from that account's
        // generation, so a delayed old response cannot evict the new candidate.
        let exchangeID = UUID()
        candidateExchangeID = exchangeID
        candidates.removeAll(); legacyCandidates.removeAll()
        func requireOwnership() throws {
            try Task.checkCancellation()
            guard epoch == self.generation, self.candidateExchangeID == exchangeID else { throw CancellationError() }
            try requireCurrentAttempt()
        }
        do {
            let response = try await legacyExchange(legacyToken, epoch: epoch, requireCurrentAttempt: requireOwnership)
            try requireOwnership()
            let candidate = try Self.decodeSession(response)
            let legacyID = try Self.decodeLegacyUserID(response)
            guard candidate.accessToken != legacyToken else { throw Self.invalidSession }
            candidates = [candidate.accessToken: candidate]
            legacyCandidates = [candidate.accessToken: SupabaseLegacyCredential(actorID: candidate.userID, legacyUserID: legacyID, accessToken: legacyToken)]
            let user = try await profile(accessToken: candidate.accessToken)
            try requireOwnership()
            return LoginResponse(accessToken: candidate.accessToken, user: user)
        } catch {
            defer {
                if candidateExchangeID == exchangeID {
                    candidateExchangeID = nil
                    candidates.removeAll(); legacyCandidates.removeAll()
                }
            }
            try requireOwnership()
            throw error
        }
    }

    private func legacyExchange(
        _ legacyToken: String, epoch: UUID,
        requireCurrentAttempt: @MainActor () throws -> Void = {}
    ) async throws -> JSONValue {
        var retries = 0
        var importRetries = 0
        while true {
            guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
            try requireCurrentAttempt()
            do {
                let response = try await request(path: "/functions/v1/legacy-session", method: "POST", body: .object(["action": .string("exchange")]), token: legacyToken)
                try requireCurrentAttempt()
                return response
            }
            catch let error as Base44Error where ["legacy_session_busy", "LEGACY_SESSION_BUSY"].contains(error.code ?? "") && retries < 2 {
                try requireCurrentAttempt()
                retries += 1
                try await Task.sleep(for: .seconds(1))
            } catch let error as Base44Error where ["legacy_import_pending", "LEGACY_IMPORT_PENDING"].contains(error.code ?? "") {
                try requireCurrentAttempt()
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
#if SPYCLASH_GAME_CENTER_EXPERIMENT
        if current.nativeCredentialKind != nil {
            return try await ensureNativeAccessToken(forceRefresh: forceLegacyValidation)
        }
#endif
        if !forceLegacyValidation, current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let epoch = generation
        let legacyToken = try legacyAccessToken()
        let legacyID = legacyCredential?.legacyUserID
        let task = Task { @MainActor in
            let json = try await self.legacyExchange(legacyToken, epoch: epoch)
            let next = try Self.decodeSession(json)
            guard self.generation == epoch, !Task.isCancelled else { throw CancellationError() }
            let nextLegacyID = try Self.decodeLegacyUserID(json)
            guard self.session?.userID == next.userID, nextLegacyID == legacyID else { throw Self.invalidSession }
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
        let isAppStoreDelivery = write && service == "membership" && action == "sync_transaction"
        let deliveryLease = isAppStoreDelivery ? try await appStoreDeliveryQueue.acquire(timeout: 120) : nil
        defer { if let deliveryLease { appStoreDeliveryQueue.release(deliveryLease) } }
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        let credential: String
        if let token { credential = token } else { credential = try await ensureAccessToken() }
        guard epoch == generation else { throw CancellationError() }
        let actorID = userID
        let legacyToken = includeLegacyCredential ? try legacyAccessToken() : nil
        let permitsLegacyCredential = (service == "legacy" && ["link", "generate"].contains(action)) ||
            (service == "membership" && ["check", "prepare", "sync_transaction"].contains(action)) ||
            (service == "profile" && action == "delete" && fields["deletion_scope"]?.string == "account")
        guard !includeLegacyCredential || permitsLegacyCredential else { throw Self.invalidSession }
        if isAppStoreDelivery, let previous = try mutationJournal.pendingAppStoreTransaction(actorID: actorID) {
            var previousSource = previous; previousSource.removeValue(forKey: "request_id")
            var currentSource = body; currentSource.removeValue(forKey: "request_id")
            if previousSource != currentSource {
                try await recoverAppStoreTransaction(previous, actorID: actorID, credential: credential,
                                                     legacyToken: legacyToken, epoch: epoch, permitsRevalidation: token == nil)
            }
        }
        if write { body = try mutationJournal.prepare(actorID: actorID, body: body) }
        do {
            var wireBody = body
            if let legacyToken { wireBody["base44_access_token"] = .string(legacyToken) }
            let value: JSONValue
            if isAppStoreDelivery {
                value = try await appStoreDeliveryRequest(body: .object(wireBody), actorID: actorID, token: credential, epoch: epoch, permitsRevalidation: token == nil)
            } else {
                value = try await authenticatedRequest(path: "/functions/v1/app-services", body: .object(wireBody), token: credential, epoch: epoch, permitsRevalidation: token == nil)
            }
            guard epoch == generation else { throw CancellationError() }
            let result = try JSONDecoder.base44.decode(T.self, from: value.data())
            if write, let requestID = body["request_id"]?.string { try mutationJournal.acknowledge(actorID: actorID, requestID: requestID) }
            return result
        } catch let error as Base44Error {
            if isAppStoreDelivery {
                try Task.checkCancellation()
                guard epoch == generation, userID == actorID else { throw CancellationError() }
            }
            // An expired/revoked credential is rejected before the command runs.
            // Preserve its immutable intent so sign-in can safely resume it.
            if write, let status = error.statusCode, (400..<500).contains(status), status != 401,
               !isAppStoreDelivery || Self.isDefinitiveAppStoreFailure(error),
               let requestID = body["request_id"]?.string {
                try mutationJournal.acknowledge(actorID: actorID, requestID: requestID)
            }
            throw error
        }
    }

    private func recoverAppStoreTransaction(_ saved: [String: JSONValue], actorID: String, credential: String,
                                            legacyToken: String?, epoch: UUID, permitsRevalidation: Bool) async throws {
        try Task.checkCancellation()
        guard epoch == generation, userID == actorID, let requestID = saved["request_id"]?.string else { throw CancellationError() }
        var wire = saved
        if let legacyToken { wire["base44_access_token"] = .string(legacyToken) }
        do {
            let value = try await appStoreDeliveryRequest(body: .object(wire), actorID: actorID, token: credential,
                                                         epoch: epoch, permitsRevalidation: permitsRevalidation)
            try Task.checkCancellation()
            guard epoch == generation, userID == actorID else { throw CancellationError() }
            let receipt = try JSONDecoder.base44.decode(AppStoreEntitlementSyncResponse.self, from: value.data())
            guard receipt.success, receipt.serverStatusVerified,
                  StoreKitSubscriptionProduct.supports(receipt.entitlement.productID) else { throw AppStoreDeliveryError.responseRejected }
            try mutationJournal.acknowledge(actorID: actorID, requestID: requestID)
            // The old receipt is intentionally discarded. The caller must
            // submit and verify its own JWS before StoreKit may finish it.
        } catch let error as Base44Error {
            try Task.checkCancellation()
            guard epoch == generation, userID == actorID else { throw CancellationError() }
            if Self.isDefinitiveAppStoreFailure(error) {
                try mutationJournal.acknowledge(actorID: actorID, requestID: requestID)
                return
            }
            throw error
        }
    }

    /// Keep the delivery lease and immutable command across short binding-lease
    /// conflicts. A retry cannot replace the account, JWS or journal request ID.
    private func appStoreDeliveryRequest(body: JSONValue, actorID: String, token: String, epoch: UUID,
                                         permitsRevalidation: Bool) async throws -> JSONValue {
        try await AppStoreTransactionRetryPolicy.perform(requireScope: {
            try Task.checkCancellation()
            guard self.generation == epoch, self.userID == actorID else { throw CancellationError() }
        }, sleep: appStoreRetrySleep) {
            try await self.authenticatedRequest(path: "/functions/v1/app-services", body: body, token: token,
                                                epoch: epoch, permitsRevalidation: permitsRevalidation)
        }
    }

    private static func isDefinitiveAppStoreFailure(_ error: Base44Error) -> Bool {
        guard let status = error.statusCode else { return false }
        return (400..<500).contains(status) && ![401, 408, 425, 429].contains(status) && !error.retryable
    }
    func fullGame(_ body: JSONValue) async throws -> JSONValue {
        let epoch = generation
        let token = try await ensureAccessToken()
        do {
            let result = try await authenticatedRequest(path: "/functions/v1/full-game-core", body: body, token: token, epoch: epoch)
            guard epoch == generation else { throw CancellationError() }
            return result
        } catch let error as Base44Error {
            // A gateway timeout, throttling response or transient credential
            // failure does not settle an earlier attempt of this request ID.
            // Keep the immutable gameplay intent until a definitive response.
            throw FullGameTransportFailure(error: error, ambiguous: !Self.isDefinitiveFullGameFailure(error))
        }
    }

    private static func isDefinitiveFullGameFailure(_ error: Base44Error) -> Bool {
        guard let status = error.statusCode else { return false }
        return (400..<500).contains(status) && ![401, 408, 425, 429].contains(status) && !error.retryable
    }

    static func decodeSession(_ value: JSONValue) throws -> SupabaseStoredSession {
        guard let access = value["access_token"].string, !access.isEmpty,
              let refresh = value["refresh_token"].string, !refresh.isEmpty,
              let user = value["user"]["id"].string, UUID(uuidString: user) != nil,
              (1...3600).contains(value["expires_in"].integer) else { throw invalidSessionResponse }
        let relativeExpiry = Date().addingTimeInterval(TimeInterval(value["expires_in"].integer))
        let expiresAt: Date
        if value["expires_at"].integer > 0 {
            expiresAt = min(relativeExpiry, Date(timeIntervalSince1970: TimeInterval(value["expires_at"].integer)))
            guard expiresAt.timeIntervalSinceNow > 0 else { throw invalidSessionResponse }
        } else { expiresAt = relativeExpiry }
        return SupabaseStoredSession(accessToken: access, refreshToken: refresh, userID: user.lowercased(), expiresAt: expiresAt)
    }

    private static func decodeLegacyUserID(_ value: JSONValue) throws -> String {
        guard let id = value["legacy_user_id"].string, !id.isEmpty, id.count <= 512 else { throw invalidSessionResponse }
        return id
    }

    /// Renew an expired transport credential once, retaining the exact command
    /// body and request UUID. Explicit revocation is not an expiry signal.
    private func authenticatedRequest(path: String, body: JSONValue, token: String, epoch: UUID, permitsRevalidation: Bool = true) async throws -> JSONValue {
        do { return try await request(path: path, method: "POST", body: body, token: token) }
        catch let error as Base44Error where permitsRevalidation && Self.requiresSessionRevalidation(error) {
            guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
            let refreshed = try await ensureAccessToken(forceLegacyValidation: true)
            guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
            return try await request(path: path, method: "POST", body: body, token: refreshed)
        }
    }

    private static func requiresSessionRevalidation(_ error: Base44Error) -> Bool {
        guard error.statusCode == 401 else { return false }
        return ["legacy_session_revalidation_required", "jwt_expired"].contains(error.code ?? "") ||
            (error.code == "http_401" && ["JWT expired", "Invalid JWT"].contains(error.message))
    }
    private func request(path: String, method: String, body: JSONValue, token: String? = nil) async throws -> JSONValue {
        let configuration = try configuration()
        var allowedFunctions = ["/functions/v1/app-services", "/functions/v1/full-game-core", "/functions/v1/legacy-session"]
#if SPYCLASH_GAME_CENTER_EXPERIMENT
        allowedFunctions = ["/functions/v1/app-services", "/functions/v1/full-game-core", "/functions/v1/game-center-session"]
#endif
        guard path.hasPrefix("/auth/v1/") || allowedFunctions.contains(path),
              let origin = URL(string: configuration.backendURL),
              let url = URL(string: configuration.backendURL + path), url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port else { throw Self.invalidSession }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if path == "/functions/v1/legacy-session" { request.timeoutInterval = 90 }
        else if path == "/functions/v1/app-services", body["service"].string == "profile", body["action"].string == "delete", body["deletion_scope"].string == "account" { request.timeoutInterval = 90 }
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
            let code = details["code"].string ?? details["error_code"].string ?? details["error"].string ?? "http_\(response.statusCode)"
            // The binding retry contract requires the server's explicit flag;
            // a generic 503 must not invent retry permission for this code.
            let retryable = code == "apple_account_binding_busy" ? details["retryable"].bool : response.statusCode >= 500 || details["retryable"].bool
            let bodyDelay: Int?
            if case .number(let seconds) = details["retry_after_seconds"], seconds.isFinite, seconds >= 0 {
                bodyDelay = Int(exactly: seconds.rounded(.up))
            } else { bodyDelay = nil }
            let headerDelay = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .flatMap { $0 >= 0 ? $0 : nil }
            throw Base44Error(message: details["message"].string ?? details["msg"].string ?? details["error_description"].string ?? "The request could not be completed.", statusCode: response.statusCode, code: code, retryable: retryable, retryAfterSeconds: bodyDelay ?? headerDelay)
        }
        return json
    }
    private static var invalidSession: Base44Error { Base44Error(message: "Please sign in again.", statusCode: 401, code: "supabase_session_missing") }
    private static var invalidSessionResponse: Base44Error {
        Base44Error(message: "The sign-in service returned an invalid response. Please try again.", statusCode: 502,
                    code: "supabase_session_response_invalid", retryable: true)
    }

#if SPYCLASH_GAME_CENTER_EXPERIMENT
    func exchangeGameCenter(proof: GameCenterIdentityProof, requireCurrentAttempt: @MainActor () throws -> Void = {}) async throws -> LoginResponse {
        let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(proof))
        return try await nativeCandidate(kind: .gameCenter, requireCurrentAttempt: requireCurrentAttempt) {
            let value = try await self.request(path: "/functions/v1/game-center-session", method: "POST", body: body)
            guard value["provider"].string == "game_center" else { throw Self.invalidSessionResponse }
            return value
        }
    }

    func nativeEmailLogin(email: String, password: String, requireCurrentAttempt: @MainActor () throws -> Void = {}) async throws -> LoginResponse {
        try await nativeCandidate(kind: .email, requireCurrentAttempt: requireCurrentAttempt) {
            try await self.request(path: "/auth/v1/token?grant_type=password", method: "POST", body: .object(["email": .string(email), "password": .string(password)]))
        }
    }

    func nativeEmailRegister(email: String, password: String, requireCurrentAttempt: @MainActor () throws -> Void = {}) async throws -> LoginResponse? {
        // A server may require email confirmation. A response with no access
        // token intentionally leaves AuthView on its existing verification step.
        do {
            return try await nativeCandidate(kind: .email, requireCurrentAttempt: requireCurrentAttempt) {
                let value = try await self.request(path: "/auth/v1/signup", method: "POST", body: .object(["email": .string(email), "password": .string(password)]))
                guard value["access_token"].string != nil else {
                    // GoTrue returns either a user object or an envelope when
                    // confirmation is pending; a blank 2xx is never success.
                    guard let id = value["id"].string ?? value["user"]["id"].string,
                          UUID(uuidString: id) != nil else { throw Self.invalidSessionResponse }
                    throw Base44Error(message: "Confirm your email to continue.", code: "email_verification_required")
                }
                return value
            }
        } catch let error as Base44Error where error.code == "email_verification_required" {
            try Task.checkCancellation(); try requireCurrentAttempt()
            return nil
        }
    }

    func nativeEmailVerify(email: String, code: String, requireCurrentAttempt: @MainActor () throws -> Void = {}) async throws -> LoginResponse {
        guard SupabaseAppRuntime.acceptsEmailOTP(code, length: 6) else {
            throw Base44Error(message: "Enter the six-digit confirmation code.", code: "invalid_email_otp")
        }
        return try await nativeCandidate(kind: .email, requireCurrentAttempt: requireCurrentAttempt) {
            try await self.request(path: "/auth/v1/verify", method: "POST", body: .object(["type": .string("signup"), "email": .string(email), "token": .string(code)]))
        }
    }

    func nativeEmailResend(email: String) async throws {
        _ = try await request(path: "/auth/v1/resend", method: "POST", body: .object(["type": .string("signup"), "email": .string(email)]))
    }

    func nativeRequestRecovery(email: String) async throws {
        _ = try await request(path: "/auth/v1/recover?redirect_to=spyclash-gamecenter000%3A%2F%2Freset-password", method: "POST", body: .object(["email": .string(email)]))
    }

    func nativeResetPassword(token: String, password: String) async throws {
        _ = try await request(path: "/auth/v1/user", method: "PUT", body: .object(["password": .string(password)]), token: token)
    }

    private func nativeCandidate(kind: SupabaseNativeCredentialKind, requireCurrentAttempt: @MainActor () throws -> Void = {}, exchange: () async throws -> JSONValue) async throws -> LoginResponse {
        try Task.checkCancellation(); try requireCurrentAttempt()
        let epoch = generation
        let exchangeID = UUID()
        candidateExchangeID = exchangeID
        candidates.removeAll(); legacyCandidates.removeAll()
        func requireOwnership() throws {
            try Task.checkCancellation()
            guard generation == epoch, candidateExchangeID == exchangeID else { throw CancellationError() }
            try requireCurrentAttempt()
        }
        do {
            let response = try await exchange()
            try requireOwnership()
            var candidate = try Self.decodeSession(response)
            candidate.nativeCredentialKind = kind
            candidates[candidate.accessToken] = candidate
            let user = try await profile(accessToken: candidate.accessToken)
            try requireOwnership()
            return LoginResponse(accessToken: candidate.accessToken, user: user)
        } catch {
            if candidateExchangeID == exchangeID {
                candidateExchangeID = nil; candidates.removeAll(); legacyCandidates.removeAll()
            }
            throw error
        }
    }

    private func ensureNativeAccessToken(forceRefresh: Bool) async throws -> String {
        guard let current = session, let kind = current.nativeCredentialKind else { throw Self.invalidSession }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let epoch = generation
        let task = Task { @MainActor in
            let json: JSONValue
            do {
                json = try await self.request(path: "/auth/v1/token?grant_type=refresh_token", method: "POST", body: .object(["refresh_token": .string(current.refreshToken)]))
            } catch let error as Base44Error where [400, 401, 403].contains(error.statusCode ?? 0)
                && ["refresh_token_not_found", "refresh_token_already_used", "invalid_grant", "session_not_found", "user_not_found", "user_banned"].contains(error.code ?? "") {
                throw Self.invalidSession
            }
            var next = try Self.decodeSession(json)
            guard self.generation == epoch, !Task.isCancelled else { throw CancellationError() }
            guard next.userID == current.userID else { throw Self.invalidSession }
            next.nativeCredentialKind = kind
            try self.persistSession(next)
            self.session = next
            return next
        }
        refreshTask = task
        defer { if generation == epoch { refreshTask = nil } }
        return try await task.value.accessToken
    }
#endif
}

private final class SupabaseNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif
