import Foundation

struct LabConfiguration: Codable {
    let backendURL: String
    let publishableKey: String
    let email: String
    let password: String
    let name: String
    var transportURL: String?

    struct Allowlist: Decodable {
        let allowedProjectRefs: [String]
        let allowedLocalOrigins: [String]
    }

    func validated() throws -> LabConfiguration {
        guard let resource = Bundle.main.url(forResource: "BackendAllowlist", withExtension: "json"),
              let url = URL(string: backendURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.path.isEmpty || components.path == "/"
        else { throw LabFailure(code: "invalid_backend_configuration") }
        let allowlist = try JSONDecoder().decode(Allowlist.self, from: Data(contentsOf: resource))
        let origin = backendURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cloudAllowed = components.scheme == "https" && components.port == nil &&
            allowlist.allowedProjectRefs.contains { components.host == "\($0).supabase.co" }
        guard cloudAllowed || allowlist.allowedLocalOrigins.contains(origin) else {
            throw LabFailure(code: "backend_not_in_compiled_test_allowlist")
        }
        guard publishableKey.hasPrefix("sb_publishable_") || Self.isAnonymousJWT(publishableKey) else {
            throw LabFailure(code: "only_publishable_or_anon_key_allowed")
        }
        guard email.lowercased().hasSuffix("@example.test") || email.lowercased().hasSuffix("@example.invalid") else {
            throw LabFailure(code: "synthetic_test_account_required")
        }
        guard !password.isEmpty, !name.isEmpty, name.count <= 32 else {
            throw LabFailure(code: "invalid_test_actor")
        }
        if let transportURL { _ = try Self.loopbackURL(transportURL) }
        return self
    }

    static func loopbackURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "http", ["127.0.0.1", "localhost", "::1", "[::1]"].contains(c.host ?? ""),
              c.port != nil, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/" else { throw LabFailure(code: "control_or_proxy_must_be_loopback") }
        return url
    }

    private static func isAnonymousJWT(_ key: String) -> Bool {
        let parts = key.split(separator: ".")
        guard parts.count == 3 else { return false }
        var part = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        part += String(repeating: "=", count: (4 - part.count % 4) % 4)
        guard let data = Data(base64Encoded: part), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        return value["role"].string == "anon"
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
