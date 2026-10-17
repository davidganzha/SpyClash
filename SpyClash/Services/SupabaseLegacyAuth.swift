#if SPYCLASH_SUPABASE
import Foundation
import Security

struct SupabaseLegacyCredential: Codable, Equatable {
    let actorID: String
    let legacyUserID: String
    let accessToken: String
}

enum SupabaseLegacyKeychain {
    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.spyclash.ios.supabasetest") + ".supabase." + SupabaseAppConfiguration.configuredProjectReference,
         kSecAttrAccount as String: "legacy-base44-v1"]
    }
    static func read() -> SupabaseLegacyCredential? {
        var query = identity
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SupabaseLegacyCredential.self, from: data)
    }
    static func save(_ credential: SupabaseLegacyCredential) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credential), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw failure }
        var query = identity; attributes.forEach { query[$0.key] = $0.value }
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw failure }
    }
    static func clear() { SecItemDelete(identity as CFDictionary) }
    private static var failure: Base44Error { Base44Error(message: "The Base44 sign-in could not be saved securely.", code: "legacy_session_storage_failed") }
}

/// Only the existing identity endpoints may use Base44 in the staging app.
/// No shared game/API token is read by this transport and redirects are rejected.
@MainActor
final class SupabaseLegacyAuth {
    static let shared = SupabaseLegacyAuth()
    private let http: URLSession
    init(session: URLSession? = nil) {
        if let session { http = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 35
            http = URLSession(configuration: configuration, delegate: LegacyAuthNoRedirectDelegate(), delegateQueue: nil)
        }
    }
    func login(email: String, password: String) async throws -> LoginResponse {
        try await request("auth/login", fields: ["email": try Self.normalizedEmail(email), "password": password])
    }
    func register(email: String, password: String) async throws {
        let _: EmptyResponse = try await request("auth/register", fields: ["email": try Self.normalizedEmail(email), "password": password])
    }
    func verify(email: String, code: String) async throws -> VerifyResponse {
        guard SupabaseAppRuntime.acceptsEmailOTP(code, length: 6) else {
            throw Base44Error(message: "Enter the 6-digit verification code.", code: "invalid_email_otp")
        }
        return try await request("auth/verify-otp", fields: ["email": try Self.normalizedEmail(email), "otp_code": code])
    }
    func resend(email: String) async throws {
        let _: EmptyResponse = try await request("auth/resend-otp", fields: ["email": try Self.normalizedEmail(email)])
    }
    func requestRecovery(email: String) async throws {
        let _: EmptyResponse = try await request("auth/reset-password-request", fields: ["email": try Self.normalizedEmail(email)])
    }
    func resetPassword(token: String, password: String) async throws {
        guard Self.isValidCredential(token), !Self.isSupabaseBearer(token) else {
            throw Base44Error(message: "Open a fresh password recovery link and try again.", code: "invalid_recovery_token")
        }
        let _: EmptyResponse = try await request("auth/reset-password", fields: ["reset_token": token, "new_password": password])
    }
    func registerProvider(legacyToken: String, appleBindingTicket: String?) async throws {
        guard Self.isValidCredential(legacyToken), !Self.isSupabaseBearer(legacyToken) else { throw Base44Error(message: "Invalid identity provider response.", code: "wrong_credential_provider") }
        var fields = ["access_token": legacyToken]
        if let appleBindingTicket, !appleBindingTicket.isEmpty { fields["apple_binding_ticket"] = appleBindingTicket }
        let function = Base44Client.providerRegistrationFunction(appleBindingTicket: appleBindingTicket)
        let response: JSONValue = try await request("functions/" + function, fields: fields)
        if appleBindingTicket?.isEmpty == false {
            guard response["success"].bool == true,
                  response["user"]["id"].string?.isEmpty == false,
                  response["user"]["email"].string?.isEmpty == false else {
                throw Base44Error(message: "Apple account binding could not be verified. Please try again.", code: "apple_binding_response_invalid")
            }
        }
    }
    static func isSupabaseBearer(_ token: String) -> Bool {
        if token.hasPrefix("sb_publishable_") || token.hasPrefix("sb_secret_") { return true }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload), let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              let issuer = json["iss"].string, let url = URL(string: issuer) else { return false }
        return url.host?.hasSuffix(".supabase.co") == true && url.path.hasPrefix("/auth/v1")
    }

    private static func normalizedEmail(_ value: String) throws -> String {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, email.utf8.count <= 320, email.contains("@"),
              !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Base44Error(message: "Enter a valid email address.", code: "invalid_email")
        }
        return email
    }

    static func isValidCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 20_000 &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private func request<T: Decodable>(_ route: String, fields: [String: String]) async throws -> T {
        guard ["auth/login", "auth/register", "auth/verify-otp", "auth/resend-otp", "auth/reset-password-request", "auth/reset-password", "functions/autoRegisterUser", "functions/autoRegisterUserV2"].contains(route) else {
            throw Base44Error(message: "This Base44 endpoint is unavailable in staging.", code: "legacy_route_disallowed")
        }
        let url = Base44Client.appBaseURL.appending(path: "/api/apps/\(Base44Client.appID)/\(route)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Base44Client.appBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Base44Client.appID, forHTTPHeaderField: "X-App-Id")
        request.httpBody = try JSONEncoder.base44.encode(fields)
        let data: Data; let response: URLResponse
        do { (data, response) = try await http.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw Base44Error(message: "Connection interrupted. Please try again.", statusCode: 503, code: "legacy_auth_transport_interrupted", retryable: true) }
        guard let response = response as? HTTPURLResponse else { throw Base44Error(message: "Invalid sign-in response.") }
        guard (200..<300).contains(response.statusCode) else {
            let json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
            let details = json["error"].object == nil ? json : json["error"]
            throw Base44Error(message: details["message"].string ?? details["error_description"].string ?? details["error"].string ?? "Sign-in could not be completed.", statusCode: response.statusCode, code: details["code"].string ?? details["error_code"].string, retryable: response.statusCode >= 500 || response.statusCode == 429 || details["retryable"].bool)
        }
        do { return try JSONDecoder.base44.decode(T.self, from: data.isEmpty ? Data("{}".utf8) : data) }
        catch { throw Base44Error(message: "The sign-in service returned an unreadable response. Please try again.", statusCode: 502, code: "legacy_auth_invalid_response", retryable: true) }
    }
}

private final class LegacyAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
#endif
